//! Persistent mirror of registry tombstones under `.fits/tombstone_cache.json`.

const std = @import("std");
const fits_registry = @import("../fs/fits_registry.zig");

const Io = std.Io;
const Dir = Io.Dir;

pub const cache_file_name: []const u8 = "tombstone_cache.json";
pub const cache_version: u32 = 1;

const CacheJson = struct {
    version: u32,
    kind: []const u8,
    entries: []EntryJson,
};

const EntryJson = struct {
    id: []const u8,
    git_commit: ?[]const u8 = null,
};

/// Builds canonical cache id `{prefix}-{n}`.
pub fn formatId(allocator: std.mem.Allocator, obj_prefix: []const u8, n: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ obj_prefix, n });
}

/// Upserts one tombstone entry and saves the cache file atomically.
pub fn putTombstone(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    id: []const u8,
    refs: fits_registry.TombstoneRefs,
) !void {
    var cache = try load(allocator, io, repo_root);
    defer cache.deinit(allocator);

    const idx = findEntryIndex(cache.entries.items, id);
    if (idx) |i| {
        if (cache.entries.items[i].git_commit) |old| allocator.free(old);
        cache.entries.items[i].git_commit = if (refs.git_commit) |c| try allocator.dupe(u8, c) else null;
    } else {
        const gc = if (refs.git_commit) |c| try allocator.dupe(u8, c) else null;
        try cache.entries.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .git_commit = gc,
        });
    }

    try save(allocator, io, repo_root, &cache);
}

/// Merges all tombstones from `reg` into the cache file.
pub fn syncFromRegistry(allocator: std.mem.Allocator, io: Io, repo_root: []const u8, reg: *const fits_registry.Registry) !void {
    for (reg.prefixes.items) |entry| {
        for (entry.tombstones.items) |ts| {
            const id = try formatId(allocator, entry.obj_prefix, ts.n);
            defer allocator.free(id);
            try putTombstone(allocator, io, repo_root, id, .{
                .git_commit = ts.git_commit,
            });
        }
    }
    for (reg.link_types.items) |lt_entry| {
        for (lt_entry.tombstones.items) |ts| {
            const id = try formatId(allocator, lt_entry.link_type, ts.n);
            defer allocator.free(id);
            try putTombstone(allocator, io, repo_root, id, .{
                .git_commit = ts.git_commit,
            });
        }
    }
}

const CacheState = struct {
    entries: std.ArrayList(EntryState),

    const EntryState = struct {
        id: []const u8,
        git_commit: ?[]const u8,
    };

    fn deinit(self: *CacheState, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.id);
            if (e.git_commit) |c| allocator.free(c);
        }
        self.entries.deinit(allocator);
    }
};

fn load(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !CacheState {
    const path = try joinCachePath(allocator, repo_root);
    defer allocator.free(path);

    var file = openPath(io, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .entries = .empty },
        else => |e| return e,
    };
    defer file.close(io);

    const max_bytes = 16 * 1024 * 1024;
    const contents = try readFileAlloc(file, io, allocator, max_bytes);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(CacheJson, allocator, contents, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.kind, "fits-tombstone-cache-v1")) return error.InvalidCacheKind;

    var state: CacheState = .{ .entries = .empty };
    errdefer state.deinit(allocator);

    for (parsed.value.entries) |ej| {
        const id_copy = try allocator.dupe(u8, ej.id);
        errdefer allocator.free(id_copy);
        const gc = if (ej.git_commit) |c| try allocator.dupe(u8, c) else null;
        try state.entries.append(allocator, .{ .id = id_copy, .git_commit = gc });
    }
    return state;
}

fn save(allocator: std.mem.Allocator, io: Io, repo_root: []const u8, state: *const CacheState) !void {
    const cwd = Dir.cwd();
    const fits_path = try std.fs.path.join(allocator, &.{ repo_root, fits_registry.fits_dir_name });
    defer allocator.free(fits_path);
    try cwd.createDirPath(io, fits_path);

    const final_path = try joinCachePath(allocator, repo_root);
    defer allocator.free(final_path);
    const tmp_path = try std.mem.concat(allocator, u8, &.{ final_path, ".tmp" });
    defer allocator.free(tmp_path);

    var entries_json = try allocator.alloc(EntryJson, state.entries.items.len);
    defer allocator.free(entries_json);
    for (state.entries.items, 0..) |e, i| {
        entries_json[i] = .{ .id = e.id, .git_commit = e.git_commit };
    }

    const envelope = CacheJson{
        .version = cache_version,
        .kind = "fits-tombstone-cache-v1",
        .entries = entries_json,
    };

    const json_text = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(envelope, .{ .whitespace = .indent_2 })});
    defer allocator.free(json_text);

    {
        var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, json_text);
        try out.sync(io);
    }

    try cwd.rename(tmp_path, cwd, final_path, io);
}

fn findEntryIndex(items: []const CacheState.EntryState, id: []const u8) ?usize {
    for (items, 0..) |e, i| {
        if (std.mem.eql(u8, e.id, id)) return i;
    }
    return null;
}

fn joinCachePath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, fits_registry.fits_dir_name, cache_file_name });
}

fn openPath(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

fn readFileAlloc(file: Io.File, io: Io, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}
