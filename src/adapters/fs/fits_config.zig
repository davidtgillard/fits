//! User-editable FITS CLI settings under `.fits/fits_config.toml` or global XDG config.

const std = @import("std");
const fits_registry = @import("fits_registry.zig");

const Io = std.Io;
const Dir = Io.Dir;

pub const config_file_name: []const u8 = "fits_config.toml";

/// Default background update check interval (seconds).
pub const default_update_check_time_period: u64 = 86400;

/// Loaded user settings.
pub const Config = struct {
    update_check_time_period: u64,
};

/// Returns true when `path` is an existing directory.
pub fn fitsDirExists(cwd: Dir, io: Io, path: []const u8) bool {
    const st = cwd.statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Resolves the config file path (caller frees).
///
/// If `{cwd}/.fits/` exists, use `{cwd}/.fits/fits_config.toml`.
/// Otherwise `$XDG_CONFIG_HOME/fits/fits_config.toml` (fallback `~/.config/fits/`).
pub fn resolveConfigPath(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd_rel: []const u8,
) ![]const u8 {
    const fits_rel = try std.fs.path.join(allocator, &.{ cwd_rel, fits_registry.fits_dir_name });
    defer allocator.free(fits_rel);

    const cwd = Dir.cwd();
    if (fitsDirExists(cwd, io, fits_rel)) {
        return std.fs.path.join(allocator, &.{ fits_rel, config_file_name });
    }
    return globalConfigPath(allocator, environ);
}

fn globalConfigPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "fits", config_file_name });
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "fits", config_file_name });
}

/// Loads config or creates the file with defaults when missing.
pub fn loadOrCreateDefault(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Config {
    const path = try resolveConfigPath(allocator, io, environ, ".");
    defer allocator.free(path);

    const cwd = Dir.cwd();
    if (cwd.statFile(io, path, .{})) |_| {
        const text = try readFileAllocPath(io, allocator, path, 64 * 1024);
        defer allocator.free(text);
        return parseConfig(text) catch |err| {
            std.debug.print("invalid {s}: malformed TOML\n", .{path});
            return err;
        };
    } else |_| {
        try writeConfig(io, allocator, path, .{
            .update_check_time_period = default_update_check_time_period,
        });
        return .{ .update_check_time_period = default_update_check_time_period };
    }
}

/// Returns whether a background update check should run now.
pub fn shouldRunBackgroundCheck(now_sec: i64, period_sec: u64, last_check_sec: i64) bool {
    if (last_check_sec <= 0) return true;
    const elapsed: u64 = if (now_sec > last_check_sec)
        @intCast(now_sec - last_check_sec)
    else
        0;
    return elapsed >= period_sec;
}

/// Parses TOML config text (used by [`loadOrCreateDefault`] and tests).
pub fn parseConfig(text: []const u8) !Config {
    var period: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "update_check_time_period")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const value_text = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            period = parsePeriodValue(value_text) catch return error.InvalidConfig;
        }
    }
    return .{
        .update_check_time_period = period orelse default_update_check_time_period,
    };
}

fn parsePeriodValue(text: []const u8) !u64 {
    if (text.len >= 2 and text[text.len - 1] == 'd') {
        const num_text = std.mem.trim(u8, text[0 .. text.len - 1], " \t");
        const days = try std.fmt.parseInt(u64, num_text, 10);
        return std.math.mul(u64, days, 86400) catch return error.InvalidConfig;
    }
    return std.fmt.parseInt(u64, text, 10);
}

fn trimComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return std.mem.trim(u8, line, " \t\r");
    return std.mem.trim(u8, line[0..hash], " \t\r");
}

fn writeConfig(io: Io, allocator: std.mem.Allocator, path: []const u8, cfg: Config) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidConfig;
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, parent);

    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);

    const body = try std.fmt.allocPrint(allocator,
        \\# FITS CLI settings (user-editable)
        \\update_check_time_period = {d}
        \\
    , .{cfg.update_check_time_period});
    defer allocator.free(body);

    {
        var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, body);
        try out.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

fn readFileAllocPath(io: Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openPath(io, path);
    defer file.close(io);
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}

fn openPath(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

test "parse period with day suffix" {
    const cfg = try parseConfig("update_check_time_period = 1d\n");
    try std.testing.expectEqual(@as(u64, 86400), cfg.update_check_time_period);
}

test "shouldRunBackgroundCheck gating" {
    try std.testing.expect(shouldRunBackgroundCheck(100_000, 86400, 0));
    try std.testing.expect(!shouldRunBackgroundCheck(100_000, 86400, 99_000));
    try std.testing.expect(shouldRunBackgroundCheck(200_000, 86400, 100_000));
}
