const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "kwsys_features_detector",
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{
        .file = b.path("src/main.cpp"),
        .flags = &.{"-std=c++26"},
    });
    exe.linkLibC();
    exe.linkLibCpp();

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&exe.step);

    const run_step = b.step("run", "run the detector");
    run_step.dependOn(&run.step);
}
