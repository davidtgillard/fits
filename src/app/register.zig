//! CLI use-cases for `fits register`: **node type** prefixes (CLI `node-type`; stored as `obj_prefix` entries in `.fits/registry.json`) and link types, plus link index rewrites when renaming link types.

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const new_node = @import("new_node.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = new_node.default_repo_root;

/// Default objects directory name under the repository root.
pub const default_objects_dir: []const u8 = new_node.default_objects_dir;

/// Registers a new node type prefix in the registry.
///
/// Deprecated: use [`runNodeType`] via `fits register node-type`.
pub fn runNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    node_prefix: []const u8,
) !void {
    if (!builtin.is_test) {
        std.debug.print("warning: `fits register new` is deprecated; use `fits register node-type {s}`\n", .{node_prefix});
    }
    return runNodeType(allocator, io, repo_root, node_prefix, false);
}

/// Registers a node type prefix; optionally records `create_folder` preference in `.fits/fits_config.toml`.
pub fn runNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    obj_prefix: []const u8,
    create_folder: bool,
) !void {
    try fits_registry.validateObjPrefix(obj_prefix);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    try reg.registerNewPrefix(obj_prefix);
    try reg.save(io, repo_root);

    if (create_folder) {
        try fits_config.mergeRepoObjTypeCreateFolder(allocator, io, repo_root, obj_prefix, true);
    }

    if (!builtin.is_test) std.debug.print("Registered node type {s}\n", .{obj_prefix});
}

/// Deprecated alias for [`runNodeType`].
pub const runObjType = runNodeType;

/// Registers a link type from `out_obj_prefix` → `in_obj_prefix` instances (`OUT` points to `IN`).
pub fn runLinkType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    link_type: []const u8,
    in_obj_prefix: []const u8,
    out_obj_prefix: []const u8,
    create_folder: bool,
) !void {
    try fits_registry.validateObjPrefix(link_type);
    try fits_registry.validateObjPrefix(in_obj_prefix);
    try fits_registry.validateObjPrefix(out_obj_prefix);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    try reg.registerNewLinkType(link_type, in_obj_prefix, out_obj_prefix);
    try reg.save(io, repo_root);

    if (create_folder) {
        try fits_config.mergeRepoLinkTypeCreateFolder(allocator, io, repo_root, link_type, true);
    }

    if (!builtin.is_test) {
        std.debug.print("Registered link type {s} (IN {s} <- OUT {s})\n", .{
            link_type,
            in_obj_prefix,
            out_obj_prefix,
        });
    }
}

/// Lists node types only (tab-separated: prefix, next).
///
/// Parameters:
/// - `allocator`: Used for registry load and sort buffer.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: nothing on success, or registry I/O / JSON errors.
pub fn runListNodeTypes(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    const items = reg.prefixes.items;
    const sorted = try allocator.alloc(fits_registry.Registry.PrefixEntry, items.len);
    defer allocator.free(sorted);
    @memcpy(sorted, items);

    std.mem.sortUnstable(fits_registry.Registry.PrefixEntry, sorted, {}, struct {
        fn less(_: void, a: fits_registry.Registry.PrefixEntry, b: fits_registry.Registry.PrefixEntry) bool {
            return std.mem.order(u8, a.obj_prefix, b.obj_prefix) == .lt;
        }
    }.less);

    for (sorted) |entry| {
        if (!builtin.is_test) std.debug.print("{s}\t{d}\n", .{ entry.obj_prefix, entry.next });
    }
}

/// Lists link types (tab-separated: link_type, in_obj_prefix, out_obj_prefix, next).
///
/// Parameters:
/// - `allocator`: Used for registry load and sort buffer.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: nothing on success, or registry I/O / JSON errors.
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
                entry.in_obj_prefix,
                entry.out_obj_prefix,
                entry.next,
            });
        }
    }
}

/// Lists node types, then link types (with section headers on stdout).
///
/// Parameters:
/// - `allocator`: Used for registry load.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: nothing on success, or registry I/O / parse errors.
pub fn runListAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    if (!builtin.is_test) std.debug.print("# node types (prefix\tnext)\n", .{});
    try runListNodeTypes(allocator, io, repo_root);
    if (!builtin.is_test) std.debug.print("# link types (link_type\tin\tout\tnext)\n", .{});
    try runListLinkTypes(allocator, io, repo_root);
}

/// Lists node types then link types (delegates to [`runListAll`]).
///
/// Parameters:
/// - `allocator`: Used for registry load.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: nothing on success, or registry I/O / parse errors.
pub fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    return runListAll(allocator, io, repo_root);
}

/// Renames a node type or link type; node renames also relocate `objects/` instances.
///
/// Deprecated: use [`runRenameType`].
pub fn runRename(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) !void {
    if (!builtin.is_test) {
        std.debug.print("warning: `fits register rename` is deprecated; use `fits register rename-type`\n", .{});
    }
    return runRenameType(allocator, io, repo_root, objects_rel, old_prefix, new_prefix);
}

/// Renames a registered node-type prefix or link type.
///
/// Node renames relocate issued instances under `objects/` and update `fits_config.toml` keys.
/// Link renames rewrite `relations/links.jsonc` rows and optional `relations/<id>/` folders.
///
/// Parameters:
/// - `allocator`: Path buffers and registry allocations.
/// - `io`: Filesystem I/O.
/// - `repo_root`: Repository root.
/// - `objects_rel`: Objects directory relative to `repo_root` (unused for pure link renames beyond API symmetry).
/// - `old_name`: Current prefix or link type name.
/// - `new_name`: Target name (must pass prefix validation).
///
/// Returns: `error.UnknownRenameTarget` when neither a node-type prefix nor link type matches `old_name`.
pub fn runRenameType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !void {
    try fits_registry.validateObjPrefix(old_name);
    try fits_registry.validateObjPrefix(new_name);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (reg.hasObjPrefix(old_name)) {
        const old_next = reg.nextForObjPrefix(old_name) orelse return error.UnknownObjPrefix;
        try reg.renamePrefix(old_name, new_name);
        try renameManagedInstances(allocator, io, repo_root, objects_rel, old_name, new_name, old_next);
        try reg.save(io, repo_root);
        try fits_config.renameRepoObjTypeCreateFolderKey(allocator, io, repo_root, old_name, new_name);
        if (!builtin.is_test) std.debug.print("Renamed node type {s} -> {s}\n", .{ old_name, new_name });
        return;
    }

    if (reg.hasLinkType(old_name)) {
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

fn renameManagedInstances(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
    old_next: u64,
) !void {
    const cwd = std.Io.Dir.cwd();
    const objects_path = try std.fs.path.join(allocator, &.{ repo_root, objects_rel });
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
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        const basename = entry.name;

        const parsed_n = parseInstanceNumeric(old_prefix, basename);
        if (parsed_n == null) continue;

        const n = parsed_n.?;
        if (n == 0 or n >= old_next) {
            if (!builtin.is_test) {
                std.debug.print("warning: skipping {s}/{s} (not in registry-issued range for {s})\n", .{
                    objects_rel, basename, old_prefix,
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

    // Pre-flight conflict check.
    for (renames.items) |pair| {
        const to_path = try std.fs.path.join(allocator, &.{ objects_path, pair.to_basename });
        defer allocator.free(to_path);

        if (pathExists(cwd, io, to_path)) {
            std.debug.print("error: rename target already exists: {s}/{s}\n", .{ objects_rel, pair.to_basename });
            return error.RenameTargetExists;
        }
    }

    // Deterministic order by source basename.
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
                objects_rel, pair.from_basename, objects_rel, pair.to_basename,
            });
        }
    }
}

fn pathExists(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

/// Parses the numeric suffix from a basename like `REQ-1` or `REQ-3 Login flow.md`.
///
/// Parameters:
/// - `obj_prefix`: Expected node type prefix.
/// - `basename`: File or directory name under `objects/`.
///
/// Returns: the numeric suffix, or `null` if the name does not match the instance pattern.
pub fn parseInstanceNumeric(obj_prefix: []const u8, basename: []const u8) ?u64 {
    if (basename.len <= obj_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, basename, obj_prefix)) return null;
    if (basename[obj_prefix.len] != '-') return null;

    var i: usize = obj_prefix.len + 1;
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
