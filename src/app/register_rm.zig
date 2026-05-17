//! CLI use-case: `fits register rm` — unregister a node type or link type.

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

    try fits_registry.validateTypeName(type_name);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (reg.hasNodeType(type_name)) {
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
    type_name: []const u8,
    reg: *fits_registry.Registry,
    opts: RemoveTypeOpts,
) !void {
    const idx = fits_registry.findNodeTypeIndex(reg.node_types.items, type_name) orelse return error.UnknownNodeType;
    const entry = reg.node_types.items[idx];

    if (entry.abstract) {
        try removeAbstractNodeType(allocator, io, repo_root, objects_rel, type_name, reg, opts);
        return;
    }

    try removeConcreteNodeType(allocator, io, repo_root, objects_rel, type_name, reg, opts);
}

fn removeAbstractNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    type_name: []const u8,
    reg: *fits_registry.Registry,
    opts: RemoveTypeOpts,
) !void {
    const children = try reg.concreteChildrenOf(allocator, type_name);
    defer {
        for (children) |c| allocator.free(c);
        allocator.free(children);
    }
    if (children.len > 0 and !opts.force) {
        if (!builtin.is_test) {
            std.debug.print("error: abstract node type {s} has concrete children; use --force --cascade to remove\n", .{type_name});
        }
        return error.TypeHasChildren;
    }
    if (opts.force) {
        const needs_cascade = try abstractTypeNeedsCascade(allocator, io, repo_root, reg, type_name, children);
        if (needs_cascade and !opts.cascade) {
            try printAbstractCascadeRequired(allocator, io, reg, repo_root, type_name, children);
            return error.CascadeRequired;
        }
        if (opts.cascade) {
            try runCascadeForAbstractType(allocator, io, repo_root, objects_rel, reg, type_name, children, opts);
        }
    }
    try reg.removeNodeType(type_name);
    try reg.save(io, repo_root);
}

fn removeConcreteNodeType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    type_name: []const u8,
    reg: *fits_registry.Registry,
    opts: RemoveTypeOpts,
) !void {
    const idx = fits_registry.findNodeTypeIndex(reg.node_types.items, type_name) orelse return error.UnknownNodeType;
    const id_prefix = reg.node_types.items[idx].id_prefix.?;

    const objects_path = try std.fs.path.join(allocator, &.{ repo_root, objects_rel });
    defer allocator.free(objects_path);

    const has_fs = try nodeTypeHasFilesystemInstances(allocator, io, objects_path, id_prefix);
    const has_live = reg.hasLiveNodeInstance(id_prefix);

    if ((has_live or has_fs) and !opts.force) {
        if (!builtin.is_test) {
            std.debug.print("error: node type {s} has instances; use --force to remove\n", .{type_name});
        }
        return error.TypeHasInstances;
    }

    if (opts.force) {
        const needs_cascade = try concreteTypeNeedsCascade(allocator, io, repo_root, reg, id_prefix);
        if (needs_cascade and !opts.cascade) {
            try printConcreteCascadeRequired(allocator, io, reg, repo_root, id_prefix);
            return error.CascadeRequired;
        }
        if (opts.cascade) {
            try runCascadeForConcreteType(allocator, io, repo_root, reg, id_prefix, opts.preserve_local);
        }
        try forceCleanupNodeFilesystem(allocator, io, reg, objects_path, id_prefix, opts.preserve_local);
    }

    try reg.removeNodeType(type_name);
    try reg.save(io, repo_root);
    try fits_config.removeRepoObjTypeCreateFolderKey(allocator, io, repo_root, id_prefix);
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

fn abstractTypeNeedsCascade(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    reg: *const fits_registry.Registry,
    abstract_type: []const u8,
    children: []const []const u8,
) !bool {
    if (children.len > 0) return true;

    const refs = try reg.linkTypesReferencingType(allocator, abstract_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    return refs.len > 0;
}

fn concreteTypeNeedsCascade(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    reg: *const fits_registry.Registry,
    id_prefix: []const u8,
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

    if (links_index.hasDanglingLinksForPrefix(reg, &loaded, id_prefix)) return true;

    const concrete_idx = fits_registry.findNodeTypeIndexByIdPrefix(reg.node_types.items, id_prefix) orelse return false;
    const concrete_type = reg.node_types.items[concrete_idx].type;

    const refs = try reg.linkTypesReferencingType(allocator, concrete_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    return refs.len > 0;
}

fn printAbstractCascadeRequired(
    allocator: std.mem.Allocator,
    io: std.Io,
    reg: *const fits_registry.Registry,
    repo_root: []const u8,
    abstract_type: []const u8,
    children: []const []const u8,
) !void {
    if (builtin.is_test) return;
    _ = io;
    _ = repo_root;

    std.debug.print("error: removing abstract node type {s} requires --cascade:\n", .{abstract_type});
    for (children) |child| {
        std.debug.print("  concrete child type {s}\n", .{child});
    }

    const refs = try reg.linkTypesReferencingType(allocator, abstract_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    for (refs) |lt| {
        std.debug.print("  link type {s} references this type\n", .{lt});
    }
}

fn printConcreteCascadeRequired(
    allocator: std.mem.Allocator,
    io: std.Io,
    reg: *const fits_registry.Registry,
    repo_root: []const u8,
    id_prefix: []const u8,
) !void {
    if (builtin.is_test) return;

    std.debug.print("error: removing node type with id prefix {s} requires --cascade:\n", .{id_prefix});

    const concrete_idx = fits_registry.findNodeTypeIndexByIdPrefix(reg.node_types.items, id_prefix) orelse return;
    const concrete_type = reg.node_types.items[concrete_idx].type;

    const refs = try reg.linkTypesReferencingType(allocator, concrete_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    for (refs) |lt| {
        std.debug.print("  link type {s} references this type\n", .{lt});
    }

    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = links_index.loadLinks(allocator, io, repo_root, reg, &rep) catch return;
    defer loaded.deinit();

    const one = [_][]const u8{id_prefix};
    for (loaded.rows()) |row| {
        const parsed_n = instance_id.parseSuffixAfterPrefix(row.id, row.link_type) orelse continue;
        if (reg.isLinkTombstoned(row.link_type, parsed_n)) continue;
        if (instance_id.parseNodeName(row.in, &one) != null or instance_id.parseNodeName(row.out, &one) != null) {
            std.debug.print("  dangling link {s}\n", .{row.id});
        }
    }
}

fn runCascadeForAbstractType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    reg: *fits_registry.Registry,
    abstract_type: []const u8,
    children: []const []const u8,
    opts: RemoveTypeOpts,
) !void {
    const refs = try reg.linkTypesReferencingType(allocator, abstract_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }
    for (refs) |lt| {
        const lt_opts = RemoveTypeOpts{ .force = true, .preserve_local = opts.preserve_local, .cascade = false };
        try removeLinkType(allocator, io, repo_root, lt, reg, lt_opts);
    }

    for (children) |child| {
        const child_opts = RemoveTypeOpts{ .force = true, .preserve_local = opts.preserve_local, .cascade = true };
        try removeConcreteNodeType(allocator, io, repo_root, objects_rel, child, reg, child_opts);
    }

    for (reg.node_types.items) |entry| {
        if (entry.abstract) continue;
        if (entry.id_prefix) |prefix| {
            _ = try links_index.removeDanglingLinksForPrefix(allocator, io, repo_root, reg, prefix, opts.preserve_local);
        }
    }
}

fn runCascadeForConcreteType(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    reg: *fits_registry.Registry,
    id_prefix: []const u8,
    preserve_local: bool,
) !void {
    _ = try links_index.removeDanglingLinksForPrefix(allocator, io, repo_root, reg, id_prefix, preserve_local);

    const concrete_idx = fits_registry.findNodeTypeIndexByIdPrefix(reg.node_types.items, id_prefix) orelse return;
    const concrete_type = reg.node_types.items[concrete_idx].type;

    const refs = try reg.linkTypesReferencingType(allocator, concrete_type);
    defer {
        for (refs) |s| allocator.free(s);
        allocator.free(refs);
    }

    for (refs) |lt| {
        const opts = RemoveTypeOpts{ .force = true, .preserve_local = preserve_local, .cascade = false };
        try removeLinkType(allocator, io, repo_root, lt, reg, opts);
    }
}

fn nodeTypeHasFilesystemInstances(
    allocator: std.mem.Allocator,
    io: std.Io,
    objects_path: []const u8,
    id_prefix: []const u8,
) !bool {
    var basenames = try objects_dir.collectPrefixBasenames(allocator, io, objects_path, id_prefix);
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

fn forceCleanupNodeFilesystem(
    allocator: std.mem.Allocator,
    io: std.Io,
    reg: *const fits_registry.Registry,
    objects_path: []const u8,
    id_prefix: []const u8,
    preserve_local: bool,
) !void {
    if (preserve_local) return;

    var basenames = try objects_dir.collectPrefixBasenames(allocator, io, objects_path, id_prefix);
    defer {
        for (basenames.items) |m| allocator.free(m.basename);
        basenames.deinit(allocator);
    }

    for (basenames.items) |m| {
        const parsed_n = register.parseInstanceNumeric(id_prefix, m.basename) orelse continue;
        if (reg.isTombstoned(id_prefix, parsed_n)) continue;
        try objects_dir.deleteInstancePath(io, objects_path, m.basename);
        if (!builtin.is_test) {
            std.debug.print("Removed {s}/{s}\n", .{ new_node.default_objects_dir, m.basename });
        }
    }
}
