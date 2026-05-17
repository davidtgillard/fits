//! Filesystem adapter: loads graph node bundles from type-scoped `nodes/` layout.

const std = @import("std");
const graph = @import("../../domain/graph.zig");
const git_ignore = @import("../git/ignore.zig");
const register = @import("../../app/register.zig");
const fits_registry = @import("fits_registry.zig");
const path_layout = @import("path_layout.zig");

const Io = std.Io;
const Dir = Io.Dir;

const max_file_bytes: usize = 16 * 1024 * 1024;

/// Loads [`NodeBundle`](graph.NodeBundle) values from disk, respecting ignore rules.
pub const Loader = struct {
    /// Used to skip paths ignored by git-style rules.
    ignore_matcher: git_ignore.IgnoreMatcher,

    /// Constructs a loader with the given ignore matcher.
    pub fn init(ignore_matcher: git_ignore.IgnoreMatcher) Loader {
        return .{
            .ignore_matcher = ignore_matcher,
        };
    }

    /// Scans concrete-type directories under `nodes/`; returns owned bundles sorted by id.
    ///
    /// Parameters:
    /// - `registry`: Used to resolve instance parent paths per concrete type.
    /// - `obj_prefixes`: Registered id prefixes (longest match when resolving basenames).
    pub fn loadNodeBundles(
        self: Loader,
        allocator: std.mem.Allocator,
        io: Io,
        repo_root: []const u8,
        nodes_rel: []const u8,
        registry: *const fits_registry.Registry,
        obj_prefixes: []const []const u8,
    ) ![]graph.NodeBundle {
        _ = nodes_rel;
        var bundles: std.ArrayListUnmanaged(graph.NodeBundle) = .empty;
        defer {
            for (bundles.items) |*b| freeBundle(allocator, b);
            bundles.deinit(allocator);
        }

        for (registry.node_types.items) |entry| {
            if (entry.abstract) continue;
            const type_dir_rel = try path_layout.nodeTypeDir(allocator, registry, entry.type);
            defer allocator.free(type_dir_rel);
            const type_dir_abs = try std.fs.path.join(allocator, &.{ repo_root, type_dir_rel });
            defer allocator.free(type_dir_abs);

            try scanInstanceParent(
                self,
                allocator,
                io,
                type_dir_rel,
                type_dir_abs,
                obj_prefixes,
                &bundles,
            );
        }

        std.mem.sortUnstable(graph.NodeBundle, bundles.items, {}, struct {
            fn less(_: void, a: graph.NodeBundle, b: graph.NodeBundle) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.less);

        return try bundles.toOwnedSlice(allocator);
    }
};

fn scanInstanceParent(
    self: Loader,
    allocator: std.mem.Allocator,
    io: Io,
    parent_rel: []const u8,
    parent_abs: []const u8,
    obj_prefixes: []const []const u8,
    bundles: *std.ArrayListUnmanaged(graph.NodeBundle),
) !void {
    var dir = cwdOpenDir(io, parent_abs) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        const rel_top = try std.fs.path.join(allocator, &.{ parent_rel, entry.name });
        defer allocator.free(rel_top);
        if (self.ignore_matcher.isIgnored(rel_top)) continue;

        const match = resolveBasename(entry.name, obj_prefixes) orelse continue;
        const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ match.prefix, match.n });
        errdefer allocator.free(id);

        const entry_path = try std.fs.path.join(allocator, &.{ parent_abs, entry.name });
        defer allocator.free(entry_path);

        var files: std.ArrayListUnmanaged(graph.NodeFile) = .empty;
        defer {
            for (files.items) |f| allocator.free(f.contents);
            for (files.items) |f| allocator.free(f.relative_path);
            files.deinit(allocator);
        }

        switch (entry.kind) {
            .directory => try walkObjectDir(allocator, io, entry_path, "", &files),
            .file => {
                if (!fileBasenameEndsWithMd(entry.name)) continue;
                const rel = try allocator.dupe(u8, entry.name);
                errdefer allocator.free(rel);
                const data = try readFileLimited(allocator, io, entry_path, max_file_bytes);
                errdefer allocator.free(data);
                try files.append(allocator, .{ .relative_path = rel, .contents = data });
            },
            else => continue,
        }

        if (files.items.len == 0) {
            allocator.free(id);
            continue;
        }

        const owned_files = try files.toOwnedSlice(allocator);
        errdefer {
            for (owned_files) |f| allocator.free(f.contents);
            for (owned_files) |f| allocator.free(f.relative_path);
            allocator.free(owned_files);
        }

        try bundles.append(allocator, .{ .id = id, .files = owned_files });
    }
}

fn freeBundle(allocator: std.mem.Allocator, bundle: *graph.NodeBundle) void {
    allocator.free(bundle.id);
    for (bundle.files) |f| allocator.free(f.contents);
    for (bundle.files) |f| allocator.free(f.relative_path);
    allocator.free(bundle.files);
    bundle.* = undefined;
}

fn fileBasenameEndsWithMd(name: []const u8) bool {
    const suf = ".md";
    if (name.len < suf.len) return false;
    return std.ascii.eqlIgnoreCase(name[name.len - suf.len ..], suf);
}

fn cwdOpenDir(io: Io, path: []const u8) Io.Dir.OpenError!Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn resolveBasename(basename: []const u8, obj_prefixes: []const []const u8) ?struct { prefix: []const u8, n: u64 } {
    var order = std.ArrayListUnmanaged(usize).empty;
    defer order.deinit(std.heap.page_allocator);
    for (0..obj_prefixes.len) |i| {
        order.append(std.heap.page_allocator, i) catch return null;
    }
    std.mem.sortUnstable(
        usize,
        order.items,
        obj_prefixes,
        struct {
            fn less(ps: []const []const u8, a: usize, b: usize) bool {
                return ps[a].len > ps[b].len;
            }
        }.less,
    );
    for (order.items) |idx| {
        const pfx = obj_prefixes[idx];
        if (register.parseInstanceNumeric(pfx, basename)) |n| {
            return .{ .prefix = pfx, .n = n };
        }
    }
    return null;
}

fn readFileLimited(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    max_bytes: usize,
) ![]const u8 {
    var f = openFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try f.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}

fn openFile(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

fn walkObjectDir(
    allocator: std.mem.Allocator,
    io: Io,
    abs_dir: []const u8,
    rel_base: []const u8,
    out: *std.ArrayListUnmanaged(graph.NodeFile),
) !void {
    var dir = try cwdOpenDir(io, abs_dir);
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        const joined_abs = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
        defer allocator.free(joined_abs);

        switch (entry.kind) {
            .directory => {
                const rc: []const u8 = if (rel_base.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ rel_base, entry.name });
                defer allocator.free(rc);
                try walkObjectDir(allocator, io, joined_abs, rc, out);
            },
            .file => {
                const rel_child: []const u8 = if (rel_base.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ rel_base, entry.name });
                errdefer allocator.free(rel_child);
                const data = try readFileLimited(allocator, io, joined_abs, max_file_bytes);
                errdefer allocator.free(data);
                try out.append(allocator, .{ .relative_path = rel_child, .contents = data });
            },
            else => continue,
        }
    }
}
