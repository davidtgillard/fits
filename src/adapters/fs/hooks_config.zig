//! Parse optional `.fits/hooks.toml` for subprocess hook commands (minimal subset).

const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

/// Parsed hooks configuration (defaults when file is missing).
pub const HooksConfig = struct {
    /// When true and argv slices are non-empty, hooks may run.
    enabled: bool = false,
    /// Full argv for the graph-node hook (`argv[0]` is the program).
    nodes_argv: []const []const u8 = &.{},
    /// Full argv for the link hook.
    links_argv: []const []const u8 = &.{},
    max_request_bytes: usize = 32 * 1024 * 1024,
    /// Wall-clock timeout for subprocess I/O (`0` = use [`std.Io.Timeout.none`]).
    timeout_ns: u64 = 0,

    /// Frees duplicated argv strings.
    pub fn deinit(self: *HooksConfig, allocator: std.mem.Allocator) void {
        for (self.nodes_argv) |s| allocator.free(s);
        allocator.free(self.nodes_argv);
        for (self.links_argv) |s| allocator.free(s);
        allocator.free(self.links_argv);
        self.* = .{};
    }
};

/// Loads `.fits/hooks.toml` under `repo_root` when present.
///
/// Parameters:
/// - `allocator`: Owns duplicated argv strings in the result.
/// - `io`: Filesystem I/O.
/// - `repo_root`: Repository root (`.` or absolute).
///
/// Returns: parsed config; use [`HooksConfig.deinit`] when done.
pub fn load(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !HooksConfig {
    const path = try std.fs.path.join(allocator, &.{ repo_root, ".fits", "hooks.toml" });
    defer allocator.free(path);

    var file = cwdOpen(io, path) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer file.close(io);

    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > 1024 * 1024) return error.FileTooBig;
    const raw = try allocator.alloc(u8, n);
    defer allocator.free(raw);
    const got = try file.readPositionalAll(io, raw, 0);
    if (got != n) return error.UnexpectedEndOfFile;

    return try parseContents(allocator, raw);
}

fn cwdOpen(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

fn parseContents(allocator: std.mem.Allocator, raw: []const u8) !HooksConfig {
    var enabled: bool = false;
    var nodes_command_raw: ?[]const u8 = null;
    var objects_command_raw: ?[]const u8 = null;
    var links_command_raw: ?[]const u8 = null;
    var max_req: ?usize = null;
    var timeout_s: ?u64 = null;

    defer {
        if (nodes_command_raw) |p| allocator.free(p);
        if (objects_command_raw) |p| allocator.free(p);
        if (links_command_raw) |p| allocator.free(p);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or t[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "enabled")) {
            enabled = std.mem.eql(u8, val, "true");
            continue;
        }
        if (std.mem.eql(u8, key, "nodes_command")) {
            if (nodes_command_raw) |p| allocator.free(p);
            nodes_command_raw = try allocator.dupe(u8, val);
            continue;
        }
        if (std.mem.eql(u8, key, "objects_command")) {
            if (objects_command_raw) |p| allocator.free(p);
            objects_command_raw = try allocator.dupe(u8, val);
            continue;
        }
        if (std.mem.eql(u8, key, "links_command")) {
            if (links_command_raw) |p| allocator.free(p);
            links_command_raw = try allocator.dupe(u8, val);
            continue;
        }
        if (std.mem.eql(u8, key, "max_request_bytes")) {
            max_req = try std.fmt.parseInt(usize, val, 10);
            continue;
        }
        if (std.mem.eql(u8, key, "timeout_secs")) {
            timeout_s = try std.fmt.parseInt(u64, val, 10);
            continue;
        }
    }

    const chosen_nodes_json = nodes_command_raw orelse objects_command_raw orelse "";

    const node_argv = try parseJsonStringArrayLine(allocator, chosen_nodes_json);
    errdefer freeArgv(allocator, node_argv);

    const lnk_argv = try parseJsonStringArrayLine(allocator, links_command_raw orelse "");
    errdefer freeArgv(allocator, lnk_argv);

    return .{
        .enabled = enabled,
        .nodes_argv = node_argv,
        .links_argv = lnk_argv,
        .max_request_bytes = max_req orelse (32 * 1024 * 1024),
        .timeout_ns = (timeout_s orelse 0) * std.time.ns_per_s,
    };
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| allocator.free(s);
    allocator.free(argv);
}

fn parseJsonStringArrayLine(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    if (line.len == 0) return &[_][]const u8{};
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return &[_][]const u8{};

    var parsed = try std.json.parseFromSlice([][]const u8, allocator, trimmed, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const duped = try allocator.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |s, i| {
        duped[i] = try allocator.dupe(u8, s);
    }
    return duped;
}
