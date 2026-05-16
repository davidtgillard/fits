const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Release artifacts must not assume SHA-NI/AVX2 (Zig std crypto.sha2); CI runners
    // often have those features while WSL2 guests and older hosts do not.
    const default_target: std.Target.Query = if (optimize != .Debug)
        .{ .cpu_model = .baseline }
    else
        .{};

    const target = b.standardTargetOptions(.{ .default_target = default_target });

    const git_commit = b.option([]const u8, "git_commit", "Embedded git commit (40 hex chars)") orelse "";
    const github_owner = b.option([]const u8, "github_owner", "GitHub owner for self-update") orelse "davidtgillard";
    const github_repo = b.option([]const u8, "github_repo", "GitHub repo for self-update") orelse "fits";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "github_owner", github_owner);
    build_options.addOption([]const u8, "github_repo", github_repo);
    build_options.addOption([]const u8, "fits_version", "0.1.0");

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
    if (optimize == .Debug) {
        b.installArtifact(exe);
    } else {
        // Drop DWARF (.debug_*) from the installed binary; keep .symtab for backtraces.
        const strip_debug = b.addSystemCommand(&.{ "strip", "--strip-debug" });
        const stripped = strip_debug.addPrefixedOutputFileArg("-o", exe.name);
        strip_debug.addFileArg(exe.getEmittedBin());
        b.getInstallStep().dependOn(&b.addInstallBinFile(stripped, exe.name).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run fits CLI");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
