//! CLI use-cases for `fits register`: manage object type prefixes in `.fits/registry.json`.

const builtin = @import("builtin");
const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const tombstone_cache = @import("../adapters/cache/tombstone_cache.zig");
const new_object = @import("new_object.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = new_object.default_repo_root;

/// Default objects directory name under the repository root.
pub const default_objects_dir: []const u8 = new_object.default_objects_dir;

/// Registers a new object type prefix in the registry.
///
/// Parameters:
/// - `allocator`: Used for registry load/save buffers.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
/// - `obj_prefix`: New prefix (validated by [`fits_registry.validateObjPrefix`]).
///
/// Returns: nothing on success.
/// On failure: validation, [`error.DuplicateObjPrefix`], or registry I/O errors.
pub fn runNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    obj_prefix: []const u8,
) !void {
    try fits_registry.validateObjPrefix(obj_prefix);

    var reg = try fits_registry.Registry.load(allocator, io, repo_root);
    defer reg.deinit();

    try reg.registerNewPrefix(obj_prefix);
    try reg.save(io, repo_root);

    if (!builtin.is_test) std.debug.print("Registered object type {s}\n", .{obj_prefix});
}

/// Lists registered object type prefixes to stdout (tab-separated: prefix, next).
///
/// Parameters:
/// - `allocator`: Used for registry load.
/// - `io`: Process I/O for registry file operations.
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: nothing on success.
/// On failure: registry I/O or parse errors.
pub fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) !void {
    var reg = try fits_registry.Registry.load(allocator, io, repo_root);
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

/// Renames an object type prefix in the registry and renames FITS-managed instances under `objects/`.
///
/// Only renames paths whose numeric suffix `n` satisfies `1 <= n < old_next` (issued range).
/// Structural `OLD-*` matches outside that range are left untouched and warned on stderr.
///
/// Parameters:
/// - `allocator`: Used for paths and rename planning.
/// - `io`: Process I/O for registry and directory operations.
/// - `repo_root`: Repository root.
/// - `objects_rel`: Objects directory relative to `repo_root`.
/// - `old_prefix`: Existing registered prefix.
/// - `new_prefix`: New prefix name.
///
/// Returns: nothing on success.
/// On failure: validation, unknown prefix, duplicate new prefix, rename conflicts, or I/O errors.
pub fn runRename(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) !void {
    try fits_registry.validateObjPrefix(old_prefix);
    try fits_registry.validateObjPrefix(new_prefix);

    var reg = try fits_registry.Registry.load(allocator, io, repo_root);
    defer reg.deinit();

    const old_next = reg.nextForObjPrefix(old_prefix) orelse return error.UnknownObjPrefix;
    try reg.renamePrefix(old_prefix, new_prefix);
    try renameManagedInstances(allocator, io, repo_root, objects_rel, old_prefix, new_prefix, old_next);
    try reg.save(io, repo_root);
    try tombstone_cache.syncFromRegistry(allocator, io, repo_root, &reg);

    if (!builtin.is_test) std.debug.print("Renamed object type {s} -> {s}\n", .{ old_prefix, new_prefix });
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
/// - `obj_prefix`: Expected object type prefix.
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
