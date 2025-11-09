const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zcompress_mod = b.addModule("zcompress", .{
        .root_source_file = b.path("src/zcompress.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libdeflate_dep = b.dependency("libdeflate", .{
        .target = target,
        .optimize = optimize,
    });

    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
    });

    zcompress_mod.linkLibrary(libdeflate_dep.artifact("deflate"));
    zcompress_mod.linkLibrary(zstd_dep.artifact("zstd"));

    const examples_exe = b.addExecutable(.{
        .name = "zcompress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        }),
    });

    b.installArtifact(examples_exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(examples_exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = zcompress_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = examples_exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
