//! Helpers for scanning and mutating paths under `objects/`.

const std = @import("std");
const register = @import("../../app/register.zig");

const Io = std.Io;

/// One basename under `objects/` matching an instance numeric suffix.
pub const InstanceMatch = struct {
    basename: []const u8,
};

/// Collects basenames under `objects_path` whose numeric suffix equals `n`.
pub fn collectInstanceMatches(
    allocator: std.mem.Allocator,
    io: Io,
    objects_path: []const u8,
    obj_prefix: []const u8,
    n: u64,
) !std.ArrayList(InstanceMatch) {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayList(InstanceMatch) = .empty;
    errdefer {
        for (out.items) |m| allocator.free(m.basename);
        out.deinit(allocator);
    }

    var dir = cwd.openDir(io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        const basename = entry.name;
        const parsed = register.parseInstanceNumeric(obj_prefix, basename);
        if (parsed == null or parsed.? != n) continue;
        const copy = try allocator.dupe(u8, basename);
        try out.append(allocator, .{ .basename = copy });
    }
    return out;
}

/// Collects every basename under `objects_path` matching `obj_prefix` (any numeric suffix).
pub fn collectPrefixBasenames(
    allocator: std.mem.Allocator,
    io: Io,
    objects_path: []const u8,
    obj_prefix: []const u8,
) !std.ArrayList(InstanceMatch) {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayList(InstanceMatch) = .empty;
    errdefer {
        for (out.items) |m| allocator.free(m.basename);
        out.deinit(allocator);
    }

    var dir = cwd.openDir(io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        const basename = entry.name;
        if (register.parseInstanceNumeric(obj_prefix, basename) == null) continue;
        const copy = try allocator.dupe(u8, basename);
        try out.append(allocator, .{ .basename = copy });
    }
    return out;
}

/// Deletes a path under `objects_path` (file or directory tree).
pub fn deleteInstancePath(io: Io, objects_path: []const u8, basename: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const full = try std.fs.path.join(std.heap.page_allocator, &.{ objects_path, basename });
    defer std.heap.page_allocator.free(full);

    const st = try cwd.statFile(io, full, .{});
    switch (st.kind) {
        .directory => try cwd.deleteTree(io, full),
        .file => try cwd.deleteFile(io, full),
        else => return error.UnsupportedNodeKind,
    }
}
