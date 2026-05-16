//! CLI use-case: `fits register rm` — unregister a node-type prefix or link type.
//!
//! Without `--force`, fails when live instances exist in the registry or on disk. Node-type
//! removal with `--force` requires `--cascade` when dangling link rows or dependent link types exist.

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const links_validate = @import("../adapters/fs/links_validate.zig");
const objects_dir = @import("../adapters/fs/objects_dir.zig");
const instance_id = @import("../domain/instance_id.zig");
const register = @import("register.zig");
const new_node = @import("new_node.zig");

/// Options for [`runRemoveType`].
pub const RemoveTypeOpts = struct {
    force: bool = false,
    preserve_local: bool = false,
    cascade: bool = false,
};

/// Unregisters a node-type prefix or link type.
///
/// Parameters:
/// - `allocator`: Path buffers and registry allocations.
/// - `io`: Filesystem I/O.
/// - `repo_root`: Repository root.
/// - `objects_rel`: Objects directory relative to `repo_root`.
/// - `type_name`: Node-type prefix or link type name.
/// - `opts`: [`RemoveTypeOpts`].
///
/// Returns: `error.UnknownRemoveTarget` when the name is not registered.
pub fn runRemoveType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    type_name: []const u8,
    opts: RemoveTypeOpts,
) !void {
    if (opts.preserve_local and !opts.force) return error.PreserveLocalRequiresForce;
    if (opts.cascade and !opts.force) return error.CascadeRequiresForce;

    try fits_registry.validateObjPrefix(type_name);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (reg.hasObjPrefix(type_name)) {
        try removeNodeType(allocator, io, repo_root, objects_rel, type_name, &reg, opts);
        if (!builtin.is_test) std.debug.print("Removed node type {s}\n", .{type_name});
        return;
    }

    if (reg.hasLinkType(type_name)) {
        try removeLinkType(allocator, io, repo_root, type_name, &reg, opts);
        if (!builtin.is_test) std.debug.print("Removed link type {s}\n", .{type_name});
        return;
    }

    return error.UnknownRemoveTarget;
}

fn removeNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    obj_prefix: []const u8,
    reg: *fits_registry.Registry,
    opts: RemoveTypeOpts,
) !void {
    const objects_path = try std.fs.path.join(allocator, &.{ repo_root, objects_rel });
    defer allocator.free(objects_path);

    const has_fs = try nodeTypeHasFilesystemInstances(allocator, io, objects_path, obj_prefix);
    const has_live = reg.hasLiveNodeInstance(obj_prefix);

    if ((has_live or has_fs) and !opts.force) {
        if (!builtin.is_test) {
            std.debug.print("error: node type {s} has instances; use --force to remove\n", .{obj_prefix});
        }
        return error.TypeHasInstances;
    }

    if (opts.force) {
        const needs_cascade = try nodeTypeNeedsCascade(allocator, io, repo_root, reg, obj_prefix);
        if (needs_cascade and !opts.cascade) {
            try printCascadeRequired(allocator, io, reg, repo_root, obj_prefix);
            return error.CascadeRequired;
        }
        if (opts.cascade) {
            try runCascadeForNodeType(allocator, io, repo_root, reg, obj_prefix, opts.preserve_local);
        }
        try forceCleanupNodeFilesystem(allocator, io, reg, objects_path, obj_prefix, opts.preserve_local);
    }

    try reg.removePrefix(obj_prefix);
    try reg.save(io, repo_root);
    try fits_config.removeRepoObjTypeCreateFolderKey(allocator, io, repo_root, obj_prefix);
}

fn removeLinkType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    link_type: []const u8,
    reg: *fits_registry.Registry,
    opts: RemoveTypeOpts,
) !void {
    const has_live = reg.hasLiveLinkInstance(link_type);
    const has_index = try linkTypeHasIndexInstances(allocator, io, repo_root, reg, link_type);

    if ((has_live or has_index) and !opts.force) {
        if (!builtin.is_test) {
            std.debug.print("error: link type {s} has instances; use --force to remove\n", .{link_type});
        }
        return error.TypeHasInstances;
    }

    if (opts.force) {
        try links_index.removeLinkTypeFromIndex(allocator, io, repo_root, reg, link_type, opts.preserve_local);
    }

    try reg.removeLinkType(link_type);
    try reg.save(io, repo_root);
    try fits_config.removeRepoLinkTypeCreateFolderKey(allocator, io, repo_root, link_type);
}

fn nodeTypeHasFilesystemInstances(
    allocator: std.mem.Allocator,
    io: std.Io,
    objects_path: []const u8,
    obj_prefix: []const u8,
) !bool {
    var basenames = try objects_dir.collectPrefixBasenames(allocator, io, objects_path, obj_prefix);
    defer {
        for (basenames.items) |m| allocator.free(m.basename);
        basenames.deinit(allocator);
    }
    return basenames.items.len > 0;
}

fn linkTypeHasIndexInstances(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    reg: *const fits_registry.Registry,
    link_type: []const u8,
) !bool {
    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = links_index.loadLinks(allocator, io, repo_root, reg, &rep) catch |err| switch (err) {
        error.LinksInvalid => return false,
        else => |e| return e,
    };
    defer loaded.deinit();

    if (!rep.isEmpty()) return false;

    for (loaded.rows()) |row| {
        if (!std.mem.eql(u8, row.link_type, link_type)) continue;
        const parsed_n = instance_id.parseSuffixAfterPrefix(row.id, link_type) orelse continue;
        if (!reg.isLinkTombstoned(link_type, parsed_n)) return true;
    }

    const cwd = std.Io.Dir.cwd();
    const rel_dir = try std.fs.path.join(allocator, &.{ repo_root, links_index.relations_dir_name });
    defer allocator.free(rel_dir);

    var dir = cwd.openDir(io, rel_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const parsed_n = instance_id.parseSuffixAfterPrefix(entry.name, link_type) orelse continue;
        if (!reg.isLinkTombstoned(link_type, parsed_n)) return true;
    }
    return false;
}

fn nodeTypeNeedsCascade(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    reg: *const fits_registry.Registry,
    obj_prefix: []const u8,
) !bool {
    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = try links_index.loadLinks(allocator, io, repo_root, reg, &rep);
    defer loaded.deinit();

    if (!rep.isEmpty()) {
        const lp = try links_index.formatLinksRelPath(allocator, repo_root);
        defer allocator.free(lp);
        rep.print(lp);
        return error.LinksInvalid;
    }

    if (links_index.hasDanglingLinksForPrefix(reg, &loaded, obj_prefix)) return true;

    const refs = try reg.linkTypesReferencingPrefix(allocator, obj_prefix);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    return refs.len > 0;
}

fn printCascadeRequired(
    allocator: std.mem.Allocator,
    io: std.Io,
    reg: *const fits_registry.Registry,
    repo_root: []const u8,
    obj_prefix: []const u8,
) !void {
    if (builtin.is_test) return;

    std.debug.print("error: removing node type {s} requires --cascade:\n", .{obj_prefix});

    const refs = try reg.linkTypesReferencingPrefix(allocator, obj_prefix);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    for (refs) |lt| {
        std.debug.print("  link type {s} references this prefix\n", .{lt});
    }

    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = links_index.loadLinks(allocator, io, repo_root, reg, &rep) catch return;
    defer loaded.deinit();

    const one = [_][]const u8{obj_prefix};
    for (loaded.rows()) |row| {
        const parsed_n = instance_id.parseSuffixAfterPrefix(row.id, row.link_type) orelse continue;
        if (reg.isLinkTombstoned(row.link_type, parsed_n)) continue;
        if (instance_id.parseNodeName(row.in, &one) != null or instance_id.parseNodeName(row.out, &one) != null) {
            std.debug.print("  dangling link {s}\n", .{row.id});
        }
    }
}

fn runCascadeForNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    reg: *fits_registry.Registry,
    obj_prefix: []const u8,
    preserve_local: bool,
) !void {
    _ = try links_index.removeDanglingLinksForPrefix(allocator, io, repo_root, reg, obj_prefix, preserve_local);

    const refs = try reg.linkTypesReferencingPrefix(allocator, obj_prefix);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }

    for (refs) |lt| {
        const opts = RemoveTypeOpts{ .force = true, .preserve_local = preserve_local, .cascade = false };
        try removeLinkType(allocator, io, repo_root, lt, reg, opts);
    }
}

fn forceCleanupNodeFilesystem(
    allocator: std.mem.Allocator,
    io: std.Io,
    reg: *const fits_registry.Registry,
    objects_path: []const u8,
    obj_prefix: []const u8,
    preserve_local: bool,
) !void {
    if (preserve_local) return;

    var basenames = try objects_dir.collectPrefixBasenames(allocator, io, objects_path, obj_prefix);
    defer {
        for (basenames.items) |m| allocator.free(m.basename);
        basenames.deinit(allocator);
    }

    for (basenames.items) |m| {
        const parsed_n = register.parseInstanceNumeric(obj_prefix, m.basename) orelse continue;
        if (reg.isTombstoned(obj_prefix, parsed_n)) continue;
        try objects_dir.deleteInstancePath(io, objects_path, m.basename);
        if (!builtin.is_test) {
            std.debug.print("Removed {s}/{s}\n", .{ new_node.default_objects_dir, m.basename });
        }
    }
}
