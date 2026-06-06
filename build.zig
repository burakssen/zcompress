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

    const tests = b.addTest(.{
        .root_module = zcompress_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const basic_exe = addExample(b, "basic", "examples/basic.zig", target, optimize, zcompress_mod);
    const stress_exe = addExample(b, "stress", "examples/stress.zig", target, optimize, zcompress_mod);

    const run_basic = b.addRunArtifact(basic_exe);
    const run_basic_step = b.step("run-basic", "Run the basic example");
    run_basic_step.dependOn(&run_basic.step);

    const run_stress = b.addRunArtifact(stress_exe);
    const run_stress_step = b.step("run-stress", "Run the stress example");
    run_stress_step.dependOn(&run_stress.step);

    if (b.args) |args| {
        run_basic.addArgs(args);
        run_stress.addArgs(args);
    }
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcompress_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        }),
    });
    b.installArtifact(exe);
    return exe;
}
