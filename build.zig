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

    // ── ZIGlite Physical Sector Durability & Fault Fuzzing Modules ───────────

    const ziglite_durability = b.addModule("ziglite_durability", .{
        .root_source_file = b.path("src/ziglite/durability.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ziglite_c_abi = b.addModule("ziglite_c_abi", .{
        .root_source_file = b.path("src/ziglite/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ziglite_fault_injector = b.addModule("ziglite_fault_injector", .{
        .root_source_file = b.path("src/ziglite/fault_injector.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ────────────────────────────────────────────────────────────────

    const controller_tests = b.addTest(.{
        .root_module = controller,
    });
    const run_controller_tests = b.addRunArtifact(controller_tests);

    const geometry_tests = b.addTest(.{
        .root_module = geometry,
    });
    const run_geometry_tests = b.addRunArtifact(geometry_tests);

    const test_fault_injector_mod = b.createModule(.{
        .root_source_file = b.path("tests/fault_injector_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_fault_injector_mod.addImport("ziglite_fault_injector", ziglite_fault_injector);
    const test_fault_injector_artifact = b.addTest(.{ .root_module = test_fault_injector_mod });
    const run_test_fault_injector = b.addRunArtifact(test_fault_injector_artifact);

    const test_durability_recovery_mod = b.createModule(.{
        .root_source_file = b.path("tests/durability_recovery_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_durability_recovery_mod.addImport("ziglite_durability", ziglite_durability);
    const test_durability_recovery_artifact = b.addTest(.{ .root_module = test_durability_recovery_mod });
    const run_test_durability_recovery = b.addRunArtifact(test_durability_recovery_artifact);

    const test_query_poison_mod = b.createModule(.{
        .root_source_file = b.path("tests/query_poison_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_query_poison_mod.addImport("ziglite_c_abi", ziglite_c_abi);
    const test_query_poison_artifact = b.addTest(.{ .root_module = test_query_poison_mod });
    const run_test_query_poison = b.addRunArtifact(test_query_poison_artifact);

    const storage_fuzzer_mod = b.createModule(.{
        .root_source_file = b.path("tests/storage_fuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_fuzzer_mod.addImport("ziglite_c_abi", ziglite_c_abi);
    const storage_fuzzer_exe = b.addExecutable(.{
        .name = "storage_fuzzer",
        .root_module = storage_fuzzer_mod,
    });
    const run_storage_fuzzer = b.addRunArtifact(storage_fuzzer_exe);

    const test_fuzz_step = b.step(
        "test-fuzz",
        "Run ZIGlite native sector mutation & offline corruption fuzzer",
    );
    test_fuzz_step.dependOn(&run_storage_fuzzer.step);

    const test_step = b.step("test", "Run all unit and durability tests");
    test_step.dependOn(&run_controller_tests.step);
    test_step.dependOn(&run_geometry_tests.step);
    test_step.dependOn(&run_test_fault_injector.step);
    test_step.dependOn(&run_test_durability_recovery.step);
    test_step.dependOn(&run_test_query_poison.step);
}
