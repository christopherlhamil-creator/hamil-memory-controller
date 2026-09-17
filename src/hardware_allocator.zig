//! Hardware-Aware Load Shedding Cascade
//!
//! Subsystem: tot_hybrid/src/hardware_allocator.zig
//! Toolchain: Zig 0.17 compatible.
//!
//! Purpose:
//!   Tracks hardware loads across the Pop!_OS and Brandys dual-host topology.
//!   Intercepts and protects Brandys when locked by compute-heavy embedding tasks
//!   or high CPU load, dynamically dropping or routing tasks according to task
//!   priority and payload geometry:
//!     - CriticalSystemOverride: Always Brandys (AVX-512 / 12GB VRAM).
//!     - HighReasoningForensic: Brandys if payload > 8192B & CPU < 90% and not lease-locked; else Pop (AVX2).
//!     - NormalDevelopment: Pop if CPU < 85% and Brandys CPU < 80% and not lease-locked; else FreeFirstCloudRouter.
//!     - LowExploration: Always FreeFirstCloudRouter ($0-cost cloud tier on Pop; never pollutes local silicon).

const std = @import("std");

pub const TaskPriority = enum(u32) {
    LowExploration = 0,
    NormalDevelopment = 1,
    HighReasoningForensic = 2,
    CriticalSystemOverride = 3,
};

pub const HardwareMetrics = struct {
    brandys_cpu_busy: u8,           // 0-100 percentage tracking
    brandys_gpu_lease_locked: bool, // Set true during large embedding matrix blocks
    pop_os_cpu_busy: u8,            // 0-100 percentage tracking
};

pub const CascadeRoutingTarget = enum(u32) {
    FreeFirstCloudRouter = 0,       // Offloads work down to Nemotron/Qwen free tiers on Pop!_OS
    LocalPopComputeAVX2 = 1,        // Local processing on Pop CPU
    LocalBrandysComputeAVX512 = 2,  // Local high-performance routing on Brandys GPU/CPU
};

/// Deterministic Load-Shedding Cascade Algorithm
pub fn evaluate_load_shedding_cascade(
    metrics: HardwareMetrics,
    priority: TaskPriority,
    payload_size: usize,
) CascadeRoutingTarget {
    // Law 1: If Brandys is locked executing a heavy embedding or matrix training job,
    // intercept and protect it from agent allocation unless the request is a Critical System Override.
    if (metrics.brandys_gpu_lease_locked and priority != TaskPriority.CriticalSystemOverride) {
        if (priority == TaskPriority.HighReasoningForensic) {
            // Drop down to local Pop execution to preserve processing availability
            return CascadeRoutingTarget.LocalPopComputeAVX2;
        }
        // Low and normal tasks are completely shed to the $0-cost external cloud tools hosted from Pop
        return CascadeRoutingTarget.FreeFirstCloudRouter;
    }

    // Law 2: Shed workloads based directly on priority thresholds and data payload scales
    switch (priority) {
        TaskPriority.LowExploration => {
            // Low exploration loops never pollute local silicon
            return CascadeRoutingTarget.FreeFirstCloudRouter;
        },
        TaskPriority.NormalDevelopment => {
            // If either local machine is experiencing heavy utilization, shed normal tasks to free tiers
            if (metrics.brandys_cpu_busy > 80 or metrics.pop_os_cpu_busy > 85) {
                return CascadeRoutingTarget.FreeFirstCloudRouter;
            }
            return CascadeRoutingTarget.LocalPopComputeAVX2;
        },
        TaskPriority.HighReasoningForensic => {
            // Heavy data packages hit Brandys AVX-512 vector pipelines directly if capacity allows
            if (payload_size > 8192 and metrics.brandys_cpu_busy < 90) {
                return CascadeRoutingTarget.LocalBrandysComputeAVX512;
            }
            return CascadeRoutingTarget.LocalPopComputeAVX2;
        },
        TaskPriority.CriticalSystemOverride => {
            // Critical overrides bypass load-shedding safeguards and assert Brandys ownership
            return CascadeRoutingTarget.LocalBrandysComputeAVX512;
        },
    }
}

/// C-ABI export function for interop with Python (tot_bridge.py / watch_popos_hw.py)
pub export fn evaluate_load_shedding_cascade_c(
    brandys_cpu_busy: u8,
    brandys_gpu_locked: u8,
    pop_cpu_busy: u8,
    priority: u32,
    payload_size: usize,
) callconv(.c) u32 {
    const task_prio: TaskPriority = switch (priority) {
        0 => .LowExploration,
        1 => .NormalDevelopment,
        2 => .HighReasoningForensic,
        3 => .CriticalSystemOverride,
        else => .LowExploration,
    };

    const metrics = HardwareMetrics{
        .brandys_cpu_busy = brandys_cpu_busy,
        .brandys_gpu_lease_locked = (brandys_gpu_locked != 0),
        .pop_os_cpu_busy = pop_cpu_busy,
    };

    const target = evaluate_load_shedding_cascade(metrics, task_prio, payload_size);
    return @intFromEnum(target);
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "Verify Load Shedding Cascade Interception Invariants - GPU Lease Lock" {
    // Simulate Brandys locked under an intensive embedding workload
    const busy_metrics = HardwareMetrics{
        .brandys_cpu_busy = 40,
        .brandys_gpu_lease_locked = true,
        .pop_os_cpu_busy = 20,
    };

    // Assert that a high-reasoning forensic agent gets successfully dropped down to Pop CPU execution
    const target_high = evaluate_load_shedding_cascade(busy_metrics, TaskPriority.HighReasoningForensic, 12000);
    try std.testing.expect(target_high == CascadeRoutingTarget.LocalPopComputeAVX2);

    // Assert that a normal development task is shed entirely to the $0-cost free cloud router on Pop!_OS
    const target_normal = evaluate_load_shedding_cascade(busy_metrics, TaskPriority.NormalDevelopment, 4000);
    try std.testing.expect(target_normal == CascadeRoutingTarget.FreeFirstCloudRouter);

    // Assert that a low exploration task is shed to free cloud router
    const target_low = evaluate_load_shedding_cascade(busy_metrics, TaskPriority.LowExploration, 500);
    try std.testing.expect(target_low == CascadeRoutingTarget.FreeFirstCloudRouter);

    // Critical system override bypasses lease lock and stays on Brandys
    const target_crit = evaluate_load_shedding_cascade(busy_metrics, TaskPriority.CriticalSystemOverride, 500);
    try std.testing.expect(target_crit == CascadeRoutingTarget.LocalBrandysComputeAVX512);
}

test "Verify Load Shedding Cascade - Low Exploration Never Pollutes Local Silicon" {
    const idle_metrics = HardwareMetrics{
        .brandys_cpu_busy = 5,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 10,
    };

    const target = evaluate_load_shedding_cascade(idle_metrics, TaskPriority.LowExploration, 1024);
    try std.testing.expect(target == CascadeRoutingTarget.FreeFirstCloudRouter);
}

test "Verify Load Shedding Cascade - Normal Development CPU Thresholds" {
    // When CPUs are below threshold (Brandys <= 80, Pop <= 85), normal dev runs on Pop
    const moderate_metrics = HardwareMetrics{
        .brandys_cpu_busy = 50,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 40,
    };
    const target_local = evaluate_load_shedding_cascade(moderate_metrics, TaskPriority.NormalDevelopment, 2048);
    try std.testing.expect(target_local == CascadeRoutingTarget.LocalPopComputeAVX2);

    // When Brandys CPU > 80%, shed normal development to free router
    const brandys_hot = HardwareMetrics{
        .brandys_cpu_busy = 85,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 30,
    };
    const target_shed_brandys = evaluate_load_shedding_cascade(brandys_hot, TaskPriority.NormalDevelopment, 2048);
    try std.testing.expect(target_shed_brandys == CascadeRoutingTarget.FreeFirstCloudRouter);

    // When Pop CPU > 85%, shed normal development to free router
    const pop_hot = HardwareMetrics{
        .brandys_cpu_busy = 20,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 90,
    };
    const target_shed_pop = evaluate_load_shedding_cascade(pop_hot, TaskPriority.NormalDevelopment, 2048);
    try std.testing.expect(target_shed_pop == CascadeRoutingTarget.FreeFirstCloudRouter);
}

test "Verify Load Shedding Cascade - High Reasoning Forensic Payload Sizing" {
    const idle_metrics = HardwareMetrics{
        .brandys_cpu_busy = 25,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 20,
    };

    // Payload > 8192 goes to Brandys AVX-512
    const target_heavy = evaluate_load_shedding_cascade(idle_metrics, TaskPriority.HighReasoningForensic, 16384);
    try std.testing.expect(target_heavy == CascadeRoutingTarget.LocalBrandysComputeAVX512);

    // Payload <= 8192 stays on Pop AVX-2
    const target_light = evaluate_load_shedding_cascade(idle_metrics, TaskPriority.HighReasoningForensic, 4096);
    try std.testing.expect(target_light == CascadeRoutingTarget.LocalPopComputeAVX2);

    // If Brandys CPU >= 90%, even heavy payload drops to Pop
    const brandys_strained = HardwareMetrics{
        .brandys_cpu_busy = 92,
        .brandys_gpu_lease_locked = false,
        .pop_os_cpu_busy = 30,
    };
    const target_fallback = evaluate_load_shedding_cascade(brandys_strained, TaskPriority.HighReasoningForensic, 16384);
    try std.testing.expect(target_fallback == CascadeRoutingTarget.LocalPopComputeAVX2);
}

test "Verify C-ABI Interop Export" {
    // Test C-ABI export function with GPU locked, HighReasoningForensic (priority=2), large payload
    const result = evaluate_load_shedding_cascade_c(40, 1, 20, 2, 12000);
    try std.testing.expectEqual(@as(u32, 1), result); // 1 == LocalPopComputeAVX2

    // Test C-ABI export with GPU locked, NormalDevelopment (priority=1)
    const result_normal = evaluate_load_shedding_cascade_c(40, 1, 20, 1, 4000);
    try std.testing.expectEqual(@as(u32, 0), result_normal); // 0 == FreeFirstCloudRouter
}
