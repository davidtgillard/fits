//! CLI use-cases for `fits register`: abstract/concrete **node types** and link types.

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const path_layout = @import("../adapters/fs/path_layout.zig");
const new_node = @import("new_node.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = new_node.default_repo_root;

/// Default objects directory name under the repository root.
pub const default_objects_dir: []const u8 = new_node.default_objects_dir;

/// Options for [`runNodeType`].
pub const NodeTypeOpts = struct {
    abstract: bool = false,
    extends: ?[]const u8 = null,
    create_folder: bool = false,
};

/// Registers a new node type (deprecated; requires `--extends` on `node-type`).
pub fn runNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    type_name: []const u8,
) !void {
    _ = allocator;
    _ = io;
    _ = repo_root;
    if (!builtin.is_test) {
        std.debug.print("warning: `fits register new` is deprecated; use `fits register node-type {s} --extends <ABSTRACT>`\n", .{type_name});
    }
    return error.ExtendsRequired;
}

/// Registers an abstract or concrete node type.
pub fn runNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    type_name: []const u8,
    opts: NodeTypeOpts,
) !void {
    try fits_registry.validateTypeName(type_name);
    if (opts.abstract and opts.extends != null) return error.AbstractRequiresNoExtends;

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (opts.abstract) {
        try reg.registerAbstractType(type_name);
    } else {
        try fits_registry.validateTypeName(opts.extends.?);
        try reg.registerConcreteType(type_name, opts.extends, null);
    }
    try reg.save(io, repo_root);

    try ensureNodeTypeDir(io, repo_root, &reg, type_name);

    if (opts.create_folder and !opts.abstract) {
        const id_prefix = reg.idPrefixForType(type_name) orelse return error.UnknownNodeType;
        try fits_config.mergeRepoObjTypeCreateFolder(allocator, io, repo_root, id_prefix, true);
    }

    if (!builtin.is_test) {
        if (opts.abstract) {
            std.debug.print("Registered abstract node type {s}\n", .{type_name});
        } else {
            std.debug.print("Registered concrete node type {s} (extends {s})\n", .{ type_name, opts.extends.? });
        }
    }
}

/// Deprecated alias for [`runNodeType`].
pub const runObjType = runNodeType;

/// Registers abstract `req`/`doc` and concrete `REQ`/`DOC` (common test fixture).
pub fn registerReqDocFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    try runNodeType(allocator, io, repo_root, "req", .{ .abstract = true });
    try runNodeType(allocator, io, repo_root, "REQ", .{ .extends = "req" });
    try runNodeType(allocator, io, repo_root, "doc", .{ .abstract = true });
    try runNodeType(allocator, io, repo_root, "DOC", .{ .extends = "doc" });
}

/// Registers abstract `req` and concrete `REQ` and `BUG` (extends `req`).
pub fn registerReqBugFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    try runNodeType(allocator, io, repo_root, "req", .{ .abstract = true });
    try runNodeType(allocator, io, repo_root, "REQ", .{ .extends = "req" });
    try runNodeType(allocator, io, repo_root, "BUG", .{ .extends = "req" });
}

/// Registers a link type from `out_type` → `in_type` instances (`OUT` points to `IN`).
pub fn runLinkType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    link_type: []const u8,
    in_type: []const u8,
    out_type: []const u8,
    create_folder: bool,
) !void {
    try fits_registry.validateTypeName(link_type);
    try fits_registry.validateTypeName(in_type);
    try fits_registry.validateTypeName(out_type);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    try reg.registerNewLinkType(link_type, in_type, out_type);
    try reg.save(io, repo_root);

    try ensureLinkTypeDir(io, repo_root, link_type);

    if (create_folder) {
        try fits_config.mergeRepoLinkTypeCreateFolder(allocator, io, repo_root, link_type, true);
    }

    if (!builtin.is_test) {
        std.debug.print("Registered link type {s} (IN {s} <- OUT {s})\n", .{
            link_type,
            in_type,
            out_type,
        });
    }
}

/// Lists node types (tab-separated: type, abstract, extends, id_prefix, next).
pub fn runListNodeTypes(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    const items = reg.node_types.items;
    const sorted = try allocator.alloc(fits_registry.Registry.NodeTypeEntry, items.len);
    defer allocator.free(sorted);
    @memcpy(sorted, items);

    std.mem.sortUnstable(fits_registry.Registry.NodeTypeEntry, sorted, {}, struct {
        fn less(_: void, a: fits_registry.Registry.NodeTypeEntry, b: fits_registry.Registry.NodeTypeEntry) bool {
            return std.mem.order(u8, a.type, b.type) == .lt;
        }
    }.less);

    for (sorted) |entry| {
        if (!builtin.is_test) {
            if (entry.abstract) {
                std.debug.print("{s}\ttrue\t\t\t0\n", .{entry.type});
            } else {
                std.debug.print("{s}\tfalse\t{s}\t{s}\t{d}\n", .{
                    entry.type,
                    entry.extends.?,
                    entry.id_prefix.?,
                    entry.next,
                });
            }
        }
    }
}

/// Lists link types (tab-separated: link_type, in_type, out_type, next).
pub fn runListLinkTypes(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    const items = reg.link_types.items;
    const sorted = try allocator.alloc(fits_registry.Registry.LinkTypeEntry, items.len);
    defer allocator.free(sorted);
    @memcpy(sorted, items);

    std.mem.sortUnstable(fits_registry.Registry.LinkTypeEntry, sorted, {}, struct {
        fn less(_: void, a: fits_registry.Registry.LinkTypeEntry, b: fits_registry.Registry.LinkTypeEntry) bool {
            return std.mem.order(u8, a.link_type, b.link_type) == .lt;
        }
    }.less);

    for (sorted) |entry| {
        if (!builtin.is_test) {
            std.debug.print("{s}\t{s}\t{s}\t{d}\n", .{
                entry.link_type,
                entry.in_type,
                entry.out_type,
                entry.next,
            });
        }
    }
}

pub fn runListAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    if (!builtin.is_test) std.debug.print("# node types (type\tabstract\textends\tid_prefix\tnext)\n", .{});
    try runListNodeTypes(allocator, io, repo_root);
    if (!builtin.is_test) std.debug.print("# link types (link_type\tin_type\tout_type\tnext)\n", .{});
    try runListLinkTypes(allocator, io, repo_root);
}

pub fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    return runListAll(allocator, io, repo_root);
}

pub fn runRename(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !void {
    if (!builtin.is_test) {
        std.debug.print("warning: `fits register rename` is deprecated; use `fits register rename-type`\n", .{});
    }
    return runRenameType(allocator, io, repo_root, objects_rel, old_name, new_name);
}

/// Renames a registered node type or link type.
pub fn runRenameType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !void {
    _ = objects_rel;
    try fits_registry.validateTypeName(old_name);
    try fits_registry.validateTypeName(new_name);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (reg.hasNodeType(old_name)) {
        const idx = fits_registry.findNodeTypeIndex(reg.node_types.items, old_name).?;
        const entry = reg.node_types.items[idx];
        const old_id_prefix_owned = if (!entry.abstract)
            try allocator.dupe(u8, entry.id_prefix.?)
        else
            null;
        defer if (old_id_prefix_owned) |p| allocator.free(p);
        const old_next = if (!entry.abstract) entry.next else 0;

        if (old_id_prefix_owned) |prefix| {
            if (std.mem.eql(u8, prefix, old_name)) {
                const new_prefix = new_name;
                try renameManagedInstances(allocator, io, repo_root, entry, new_name, prefix, new_prefix, old_next);
            }
        }

        try renameNodeTypeDir(allocator, io, repo_root, entry, new_name);
        try reg.renameNodeType(old_name, new_name);
        try reg.save(io, repo_root);

        if (old_id_prefix_owned) |prefix| {
            if (std.mem.eql(u8, prefix, old_name)) {
                try fits_config.renameRepoObjTypeCreateFolderKey(allocator, io, repo_root, prefix, new_name);
            }
        }
        if (!builtin.is_test) std.debug.print("Renamed node type {s} -> {s}\n", .{ old_name, new_name });
        return;
    }

    if (reg.hasLinkType(old_name)) {
        try renameLinkTypeDir(allocator, io, repo_root, old_name, new_name);
        try links_index.rewriteLinkTypeRows(allocator, io, repo_root, old_name, new_name);
        try reg.renameLinkType(old_name, new_name);
        try fits_config.renameRepoLinkTypeCreateFolderKey(allocator, io, repo_root, old_name, new_name);
        try reg.save(io, repo_root);
        if (!builtin.is_test) std.debug.print("Renamed link type {s} -> {s}\n", .{ old_name, new_name });
        return;
    }

    return error.UnknownRenameTarget;
}

const RenamePair = struct {
    from_basename: []const u8,
    to_basename: []const u8,
};

fn ensureNodeTypeDir(io: std.Io, repo_root: []const u8, reg: *const fits_registry.Registry, type_name: []const u8) !void {
    const rel = try path_layout.nodeTypeDir(std.heap.page_allocator, reg, type_name);
    defer std.heap.page_allocator.free(rel);
    const abs = try std.fs.path.join(std.heap.page_allocator, &.{ repo_root, rel });
    defer std.heap.page_allocator.free(abs);
    try std.Io.Dir.cwd().createDirPath(io, abs);
}

fn ensureLinkTypeDir(io: std.Io, repo_root: []const u8, link_type: []const u8) !void {
    const rel = try path_layout.linkTypeDir(std.heap.page_allocator, link_type);
    defer std.heap.page_allocator.free(rel);
    const abs = try std.fs.path.join(std.heap.page_allocator, &.{ repo_root, rel });
    defer std.heap.page_allocator.free(abs);
    try std.Io.Dir.cwd().createDirPath(io, abs);
}

fn renameNodeTypeDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    entry: fits_registry.Registry.NodeTypeEntry,
    new_name: []const u8,
) !void {
    const old_rel = try path_layout.nodeTypeDirFromFields(allocator, entry.type, entry.abstract, entry.extends);
    defer allocator.free(old_rel);
    const new_rel = try path_layout.nodeTypeDirFromFields(allocator, new_name, entry.abstract, entry.extends);
    defer allocator.free(new_rel);
    if (std.mem.eql(u8, old_rel, new_rel)) return;

    const cwd = std.Io.Dir.cwd();
    const old_abs = try std.fs.path.join(allocator, &.{ repo_root, old_rel });
    defer allocator.free(old_abs);
    const new_abs = try std.fs.path.join(allocator, &.{ repo_root, new_rel });
    defer allocator.free(new_abs);

    cwd.rename(old_abs, cwd, new_abs, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn renameLinkTypeDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    old_link_type: []const u8,
    new_link_type: []const u8,
) !void {
    const old_rel = try path_layout.linkTypeDir(allocator, old_link_type);
    defer allocator.free(old_rel);
    const new_rel = try path_layout.linkTypeDir(allocator, new_link_type);
    defer allocator.free(new_rel);
    if (std.mem.eql(u8, old_rel, new_rel)) return;

    const cwd = std.Io.Dir.cwd();
    const old_abs = try std.fs.path.join(allocator, &.{ repo_root, old_rel });
    defer allocator.free(old_abs);
    const new_abs = try std.fs.path.join(allocator, &.{ repo_root, new_rel });
    defer allocator.free(new_abs);

    cwd.rename(old_abs, cwd, new_abs, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn renameManagedInstances(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    entry: fits_registry.Registry.NodeTypeEntry,
    new_type_name: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
    old_next: u64,
) !void {
    const cwd = std.Io.Dir.cwd();
    const old_parent_rel = try path_layout.nodeTypeDirFromFields(allocator, entry.type, entry.abstract, entry.extends);
    defer allocator.free(old_parent_rel);
    _ = new_type_name;
    const objects_path = try std.fs.path.join(allocator, &.{ repo_root, old_parent_rel });
    defer allocator.free(objects_path);

    var dir = cwd.openDir(io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var renames: std.ArrayList(RenamePair) = .empty;
    defer {
        for (renames.items) |pair| {
            allocator.free(pair.from_basename);
            allocator.free(pair.to_basename);
        }
        renames.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        if (dir_entry.kind == .sym_link) continue;
        const basename = dir_entry.name;

        const parsed_n = parseInstanceNumeric(old_prefix, basename);
        if (parsed_n == null) continue;

        const n = parsed_n.?;
        if (n == 0 or n >= old_next) {
            if (!builtin.is_test) {
                std.debug.print("warning: skipping {s}/{s} (not in registry-issued range for {s})\n", .{
                    old_parent_rel, basename, old_prefix,
                });
            }
            continue;
        }

        const to_basename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ new_prefix, basename[old_prefix.len..] });
        errdefer allocator.free(to_basename);

        const from_copy = try allocator.dupe(u8, basename);
        errdefer allocator.free(from_copy);

        try renames.append(allocator, .{ .from_basename = from_copy, .to_basename = to_basename });
    }

    for (renames.items) |pair| {
        const to_path = try std.fs.path.join(allocator, &.{ objects_path, pair.to_basename });
        defer allocator.free(to_path);

        if (pathExists(cwd, io, to_path)) {
            std.debug.print("error: rename target already exists: {s}/{s}\n", .{ old_parent_rel, pair.to_basename });
            return error.RenameTargetExists;
        }
    }

    std.mem.sortUnstable(RenamePair, renames.items, {}, struct {
        fn less(_: void, a: RenamePair, b: RenamePair) bool {
            return std.mem.order(u8, a.from_basename, b.from_basename) == .lt;
        }
    }.less);

    for (renames.items) |pair| {
        const from_path = try std.fs.path.join(allocator, &.{ objects_path, pair.from_basename });
        defer allocator.free(from_path);
        const to_path = try std.fs.path.join(allocator, &.{ objects_path, pair.to_basename });
        defer allocator.free(to_path);

        try cwd.rename(from_path, cwd, to_path, io);
        if (!builtin.is_test) {
            std.debug.print("Renamed {s}/{s} -> {s}/{s}\n", .{
                old_parent_rel, pair.from_basename, old_parent_rel, pair.to_basename,
            });
        }
    }
}

fn pathExists(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

/// Parses the numeric suffix from a basename like `REQ-1` or `REQ-3 Login flow.md`.
pub fn parseInstanceNumeric(id_prefix: []const u8, basename: []const u8) ?u64 {
    if (basename.len <= id_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, basename, id_prefix)) return null;
    if (basename[id_prefix.len] != '-') return null;

    var i: usize = id_prefix.len + 1;
    if (i >= basename.len) return null;

    var n: u64 = 0;
    var digits: usize = 0;
    while (i < basename.len and std.ascii.isDigit(basename[i])) : (i += 1) {
        n *%= 10;
        n +%= basename[i] - '0';
        digits += 1;
    }
    if (digits == 0) return null;
    if (!instanceSuffixValid(basename, i)) return null;
    return n;
}

fn instanceSuffixValid(basename: []const u8, after_digits: usize) bool {
    if (after_digits == basename.len) return true;
    if (basename[after_digits] == ' ') return true;
    if (std.mem.eql(u8, basename[after_digits..], ".md")) return true;
    if (std.mem.endsWith(u8, basename, ".md")) {
        const stem = basename[0 .. basename.len - 3];
        if (after_digits < stem.len and stem[after_digits] == ' ') return true;
    }
    return false;
}

test "parseInstanceNumeric" {
    try std.testing.expectEqual(@as(?u64, 1), parseInstanceNumeric("REQ", "REQ-1"));
    try std.testing.expectEqual(@as(?u64, 3), parseInstanceNumeric("REQ", "REQ-3 Login flow"));
    try std.testing.expectEqual(@as(?u64, 1), parseInstanceNumeric("REQ", "REQ-1.md"));
    try std.testing.expectEqual(@as(?u64, 3), parseInstanceNumeric("REQ", "REQ-3 Login flow.md"));
    try std.testing.expectEqual(@as(?u64, null), parseInstanceNumeric("REQ", "REQ-"));
    try std.testing.expectEqual(@as(?u64, null), parseInstanceNumeric("REQ", "FOO-1"));
    try std.testing.expectEqual(@as(?u64, null), parseInstanceNumeric("REQ", "REQ-abc"));
}
