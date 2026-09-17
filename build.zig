const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core Modules ─────────────────────────────────────────────────────────

    const geometry = b.addModule("geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const simd = b.addModule("simd", .{
        .root_source_file = b.path("src/simd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const simd_kernels = b.addModule("simd_kernels", .{
        .root_source_file = b.path("src/simd_kernels.zig"),
        .target = target,
        .optimize = optimize,
    });
    simd_kernels.addImport("geometry", geometry);

    const gate_lattice_laws = b.addModule("gate_lattice_laws", .{
        .root_source_file = b.path("src/gate_lattice_laws.zig"),
        .target = target,
        .optimize = optimize,
    });
    gate_lattice_laws.addImport("geometry", geometry);

    const controller = b.addModule("controller", .{
        .root_source_file = b.path("src/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    controller.addImport("geometry", geometry);
    controller.addImport("gate_lattice_laws", gate_lattice_laws);
    controller.addImport("simd", simd);

    const mitosis = b.addModule("mitosis", .{
        .root_source_file = b.path("src/mitosis.zig"),
        .target = target,
        .optimize = optimize,
    });
    mitosis.addImport("geometry", geometry);

    const ipc_ring = b.addModule("ipc_ring", .{
        .root_source_file = b.path("src/ipc_ring.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_ring.addImport("geometry", geometry);

    const interconnect_bus = b.addModule("interconnect_bus", .{
        .root_source_file = b.path("src/interconnect_bus.zig"),
        .target = target,
        .optimize = optimize,
    });
    interconnect_bus.addImport("geometry", geometry);

    // ── Static Library ───────────────────────────────────────────────────────

    const lib = b.addLibrary(.{
        .name = "hamil_memory_controller",
        .root_module = controller,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── Tests ────────────────────────────────────────────────────────────────

    const controller_tests = b.addTest(.{
        .root_module = controller,
    });
    const run_controller_tests = b.addRunArtifact(controller_tests);

    const geometry_tests = b.addTest(.{
        .root_module = geometry,
    });
    const run_geometry_tests = b.addRunArtifact(geometry_tests);

    const test_step = b.step("test", "Run memory controller unit tests");
    test_step.dependOn(&run_controller_tests.step);
    test_step.dependOn(&run_geometry_tests.step);
}
