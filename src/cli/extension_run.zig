//! Run persona extension commands as subprocesses with a documented environment.

const std = @import("std");
const Io = std.Io;

/// Spawns `argv` with persona env vars appended to the process environment.
pub fn runExtensionArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    repo_root: []const u8,
    persona_id: []const u8,
    persona_version: []const u8,
    argv: []const []const u8,
) !void {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    for (environ.keys()) |key| {
        const value = environ.get(key) orelse continue;
        try env_map.put(key, value);
    }
    try env_map.put("FITS_REPO_ROOT", repo_root);
    try env_map.put("FITS_PERSONA_ID", persona_id);
    try env_map.put("FITS_PERSONA_VERSION", persona_version);

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = &env_map,
        .cwd = .inherit,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.ExtensionCommandFailed;
        },
        else => return error.ExtensionCommandFailed,
    }
}

/// Resolves hook/program path: relative names are looked up under package `bin/`.
pub fn resolveProgramPath(
    allocator: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    program: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(program)) return try allocator.dupe(u8, program);
    if (std.mem.indexOfAny(u8, program, "/\\") != null) {
        return try std.fs.path.join(allocator, &.{ package_root, program });
    }
    const bin_path = try std.fs.path.join(allocator, &.{ package_root, "bin", program });
    if (pathExists(io, bin_path)) return bin_path;
    allocator.free(bin_path);
    return try allocator.dupe(u8, program);
}

/// Builds full argv with resolved executable path at index 0.
pub fn resolveHookArgv(
    allocator: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    argv: []const []const u8,
) ![]const []const u8 {
    if (argv.len == 0) return &.{};
    const prog = try resolveProgramPath(allocator, io, package_root, argv[0]);
    errdefer allocator.free(prog);
    const out = try allocator.alloc([]const u8, argv.len);
    out[0] = prog;
    for (argv[1..], 0..) |arg, i| {
        out[i + 1] = try allocator.dupe(u8, arg);
    }
    return out;
}

fn pathExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    return true;
}
