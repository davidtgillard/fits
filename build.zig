const std = @import("std");
const pkg = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const default_target: std.Target.Query = if (optimize != .Debug)
        .{ .cpu_model = .baseline }
    else
        .{};

    const target = b.standardTargetOptions(.{ .default_target = default_target });

    const enable_cli = b.option(bool, "cli", "Build legacy fits CLI executable") orelse false;

    const api_version_packed: u32 = (@as(u32, pkg.abi_version_major) << 16) | pkg.abi_version_minor;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "fits_version", pkg.version);
    build_options.addOption(u32, "fits_api_version_packed", api_version_packed);
    if (enable_cli) {
        build_options.addOption([]const u8, "git_commit", b.option([]const u8, "git_commit", "Embedded git commit") orelse "");
        build_options.addOption([]const u8, "github_owner", b.option([]const u8, "github_owner", "GitHub owner") orelse "davidtgillard");
        build_options.addOption([]const u8, "github_repo", b.option([]const u8, "github_repo", "GitHub repo") orelse "fits");
    }

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/libfits.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_module.addImport("build_options", build_options.createModule());

    const lib_opts = b.addLibrary(.{
        .name = "fits",
        .linkage = .static,
        .root_module = lib_module,
    });
    const shared_opts = b.addLibrary(.{
        .name = "fits",
        .linkage = .dynamic,
        .root_module = lib_module,
    });

    const fits_core_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("include/fits_core.h.in") },
    }, .{
        .FITS_API_VERSION_MAJOR = pkg.abi_version_major,
        .FITS_API_VERSION_MINOR = pkg.abi_version_minor,
    });
    lib_opts.installHeader(fits_core_h.getOutputFile(), "fits_core.h");
    lib_opts.installHeader(b.path("include/libfits.h"), "libfits.h");

    const install_abi_schemas = b.addInstallDirectory(.{
        .source_dir = b.path("schemas/abi"),
        .install_dir = .prefix,
        .install_subdir = "schemas/abi",
    });
    b.getInstallStep().dependOn(&install_abi_schemas.step);

    b.installArtifact(lib_opts);
    b.installArtifact(shared_opts);

    const unit_tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const abi_module = b.createModule(.{
        .root_source_file = b.path("tests/c_abi/abi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_module.addIncludePath(fits_core_h.getOutputDir());
    abi_module.addIncludePath(b.path("include"));
    abi_module.addImport("build_options", build_options.createModule());
    abi_module.linkLibrary(lib_opts);

    const abi_test_exe = b.addExecutable(.{
        .name = "libfits_abi_test",
        .root_module = abi_module,
    });
    const run_abi = b.addRunArtifact(abi_test_exe);
    const abi_step = b.step("abi-test", "Run libfits C ABI tests");
    abi_step.dependOn(&run_abi.step);

    if (enable_cli) {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        cli_module.addImport("build_options", build_options.createModule());
        cli_module.addImport("libfits", lib_module);
        cli_module.linkLibrary(lib_opts);

        const exe = b.addExecutable(.{
            .name = "fits",
            .root_module = cli_module,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run fits CLI");
        run_step.dependOn(&run_cmd.step);
    }

    const kcov_cmd = b.graph.environ_map.get("KCOV") orelse "kcov";
    const cov_tests = b.addTest(.{
        .root_module = lib_module,
    });
    cov_tests.use_llvm = true;

    const include_path = b.fmt("--include-path={s}", .{b.pathFromRoot("src")});
    const run_kcov = b.addSystemCommand(&.{
        kcov_cmd,
        include_path,
        "--exclude-pattern=zig-cache,zig-out,/usr/",
        "--dump-summary",
    });
    run_kcov.addDirectoryArg(b.path("zig-out/coverage"));
    run_kcov.addArtifactArg(cov_tests);
    run_kcov.setEnvironmentVariable("FITS_NO_UPDATE_CHECK", "1");

    const coverage_step = b.step("coverage", "Run tests with kcov");
    coverage_step.dependOn(&run_kcov.step);
}
