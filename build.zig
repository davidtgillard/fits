const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const git_commit = b.option([]const u8, "git_commit", "Embedded git commit (40 hex chars)") orelse "";
    const github_owner = b.option([]const u8, "github_owner", "GitHub owner for self-update") orelse "davidtgillard";
    const github_repo = b.option([]const u8, "github_repo", "GitHub repo for self-update") orelse "fits";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "github_owner", github_owner);
    build_options.addOption([]const u8, "github_repo", github_repo);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("build_options", build_options.createModule());

    const exe = b.addExecutable(.{
        .name = "fits",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run FITS CLI");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
