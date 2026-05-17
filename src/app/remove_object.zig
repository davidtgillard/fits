//! CLI use-case: remove a graph **object** (a **node** under `nodes/` or a **link** row), tombstone ids, and optionally record removal in VCS.

const builtin = @import("builtin");
const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const nodes_dir = @import("../adapters/fs/nodes_dir.zig");
const path_layout = @import("../adapters/fs/path_layout.zig");
const git_removal = @import("../adapters/git/removal.zig");
const instance_id = @import("../domain/instance_id.zig");
const vcs_removal = @import("../domain/vcs_removal.zig");
const new_node = @import("new_node.zig");
const remove_link = @import("remove_link.zig");

pub const default_repo_root: []const u8 = new_node.default_repo_root;
pub const default_objects_dir: []const u8 = new_node.default_objects_dir;

/// Removes graph object `id_arg` after disambiguation (node-type prefixes are tried before link types).
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    id_arg: []const u8,
) !void {
    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    const obj_prefs = try reg.idPrefixSlice(allocator);
    defer allocator.free(obj_prefs);
    const link_prefs = try reg.linkTypeSlice(allocator);
    defer allocator.free(link_prefs);

    const target_inst = instance_id.parseRmTarget(id_arg, obj_prefs, link_prefs) orelse return error.InvalidObjName;

    switch (target_inst) {
        .link => return remove_link.run(allocator, io, repo_root, id_arg),
        .node => try runRemoveNodeOnly(allocator, io, repo_root, objects_rel, id_arg, &reg),
    }
}

fn runRemoveNodeOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    obj_name: []const u8,
    reg: *fits_registry.Registry,
) !void {
    const prefix_slice = try reg.idPrefixSlice(allocator);
    defer allocator.free(prefix_slice);

    const parsed = instance_id.parseNodeName(obj_name, prefix_slice) orelse return error.InvalidObjName;
    const obj_prefix = parsed.node_prefix;
    const n = parsed.n;

    const next_val = reg.nextForIdPrefix(obj_prefix) orelse return error.UnknownIdPrefix;
    if (n == 0 or n >= next_val) return error.NotInIssuedRange;
    if (reg.isTombstoned(obj_prefix, n)) return error.AlreadyTombstoned;

    _ = objects_rel;
    const instance_parent_rel = try path_layout.nodeInstanceParent(allocator, reg, obj_prefix);
    defer allocator.free(instance_parent_rel);
    const instance_parent_abs = try std.fs.path.join(allocator, &.{ repo_root, instance_parent_rel });
    defer allocator.free(instance_parent_abs);

    var matches = try nodes_dir.collectInstanceMatches(allocator, io, instance_parent_abs, obj_prefix, n);
    defer {
        for (matches.items) |m| allocator.free(m.basename);
        matches.deinit(allocator);
    }
    if (matches.items.len == 0) return error.NothingToRemove;

    var rel_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (rel_paths.items) |p| allocator.free(p);
        rel_paths.deinit(allocator);
    }
    for (matches.items) |m| {
        const rel = try std.fs.path.join(allocator, &.{ instance_parent_rel, m.basename });
        try rel_paths.append(allocator, rel);
    }

    var merged: vcs_removal.RemovalRecord = .{};
    defer freeOwnedRemovalRecord(allocator, &merged);

    const message = try std.fmt.allocPrint(allocator, "fits rm: {s}", .{obj_name});
    defer allocator.free(message);

    var git_backend = git_removal.GitRemovalBackend.init();
    const backend = git_backend.asInterface();
    const use_git = backend.isAvailable(io, repo_root);

    if (use_git) {
        merged = try backend.recordRemoval(allocator, io, repo_root, rel_paths.items, message);
        if (!builtin.is_test) {
            for (matches.items) |m| {
                std.debug.print("Removed {s}/{s}\n", .{ instance_parent_rel, m.basename });
            }
        }
    } else {
        for (matches.items) |m| {
            try nodes_dir.deleteInstancePath(io, instance_parent_abs, m.basename);
            if (!builtin.is_test) {
                std.debug.print("Removed {s}/{s}\n", .{ instance_parent_rel, m.basename });
            }
        }
    }

    const refs = fits_registry.TombstoneRefs{
        .git_commit = merged.git_commit,
    };
    try reg.tombstoneNumeric(obj_prefix, n, refs);
    try reg.save(io, repo_root);

    if (!builtin.is_test) {
        if (merged.git_commit) |sha| {
            const short = if (sha.len > 7) sha[0..7] else sha;
            std.debug.print("Tombstoned {s} (git_commit {s}; use: git show {s})\n", .{ obj_name, short, sha });
        } else {
            std.debug.print("Tombstoned {s}\n", .{obj_name});
        }
    }
}

fn freeOwnedRemovalRecord(allocator: std.mem.Allocator, record: *vcs_removal.RemovalRecord) void {
    if (record.git_commit) |c| allocator.free(c);
    record.* = .{};
}
