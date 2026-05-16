//! Parse repo-root `fits.zon` for persona binding metadata (minimal field scan).

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const persona_manifest = @import("../../cli/persona_manifest.zig");

const Io = std.Io;

const ParsedZon = struct {
    persona: ?[]const u8 = null,
    persona_min_version: ?[]const u8 = null,

    fn deinit(self: *ParsedZon, allocator: std.mem.Allocator) void {
        if (self.persona) |p| allocator.free(p);
        if (self.persona_min_version) |v| allocator.free(v);
        self.* = .{};
    }
};

/// Reads `.persona` from a `fits.zon` file when present.
pub fn readPersonaId(allocator: std.mem.Allocator, io: Io, zon_path: []const u8) ![]const u8 {
    const contents = try readFile(allocator, io, zon_path);
    defer allocator.free(contents);
    var parsed = try parseZonFields(allocator, contents);
    defer parsed.deinit(allocator);
    const id = parsed.persona orelse return error.PersonaNotDeclared;
    return try allocator.dupe(u8, id);
}

/// When repo has `fits.zon`, ensures it matches the invoked persona id and min version.
pub fn checkRepoPersonaBinding(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    persona_id: []const u8,
) !void {
    const zon_path = findFitsZonUp(allocator, io, cwd) orelse return;
    defer allocator.free(zon_path);

    const contents = try readFile(allocator, io, zon_path);
    defer allocator.free(contents);
    var parsed = try parseZonFields(allocator, contents);
    defer parsed.deinit(allocator);

    if (parsed.persona) |declared| {
        if (!std.mem.eql(u8, declared, persona_id)) {
            if (!builtin.is_test) {
                std.debug.print(
                    "fits.zon declares persona '{s}' but executable is '{s}'\n",
                    .{ declared, persona_id },
                );
            }
            return error.PersonaRepoMismatch;
        }
    }

    if (parsed.persona_min_version) |min_v| {
        if (!persona_manifest.isVersionCompatible(build_options.fits_version, min_v)) {
            if (!builtin.is_test) {
                std.debug.print("fits.zon requires persona_min_version >= {s}\n", .{min_v});
            }
            return error.PersonaVersionIncompatible;
        }
    }
}

fn parseZonFields(allocator: std.mem.Allocator, contents: []const u8) !ParsedZon {
    var out: ParsedZon = .{};
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, ".persona_min_version")) {
            out.persona_min_version = try parseZonStringValue(allocator, t);
            continue;
        }
        if (std.mem.startsWith(u8, t, ".persona")) {
            out.persona = try parseZonStringValue(allocator, t);
            continue;
        }
    }
    return out;
}

fn parseZonStringValue(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidFitsZon;
    const val = std.mem.trim(u8, line[eq + 1 ..], " \t,");
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return try allocator.dupe(u8, val[1 .. val.len - 1]);
    }
    return try allocator.dupe(u8, val);
}

fn findFitsZonUp(allocator: std.mem.Allocator, io: Io, start_cwd: []const u8) ?[]const u8 {
    var dir_path = std.mem.Allocator.dupe(allocator, u8, start_cwd) catch return null;
    defer allocator.free(dir_path);

    while (true) {
        const zon_path = std.fs.path.join(allocator, &.{ dir_path, "fits.zon" }) catch return null;
        if (pathExistsFile(io, zon_path)) {
            return zon_path;
        }
        allocator.free(zon_path);

        const parent = std.fs.path.dirname(dir_path) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir_path)) break;
        const next = std.mem.Allocator.dupe(allocator, u8, parent) catch break;
        allocator.free(dir_path);
        dir_path = next;
    }
    return null;
}

fn pathExistsFile(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.openFileAbsolute(io, path, .{})
    else
        try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > 1024 * 1024) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}
