//! Type-scoped repository paths under `nodes/` and `links/`.
//! Centralizes layout rules for instances, type scaffolding, and link payloads.

const std = @import("std");
const fits_registry = @import("fits_registry.zig");

/// Root directory for node type scaffolding and instances.
pub const nodes_root: []const u8 = "nodes";

/// Root directory for link type scaffolding and payloads.
pub const links_root: []const u8 = "links";

/// Link index filename inside [`links_root`].
pub const links_file_name: []const u8 = "links.jsonc";

/// Returns [`nodes_root`].
pub fn nodesRoot() []const u8 {
    return nodes_root;
}

/// Returns [`links_root`].
pub fn linksRoot() []const u8 {
    return links_root;
}

/// Relative path to `links/links.jsonc` from `repo_root` (`.` → `links/links.jsonc`).
///
/// Parameters:
/// - `allocator`: Used for the returned path.
/// - `repo_root`: Repository root (`.` or absolute).
///
/// Returns: owned path; caller must free.
pub fn linksIndexRel(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    if (std.mem.eql(u8, repo_root, ".")) {
        return std.fs.path.join(allocator, &.{ links_root, links_file_name });
    }
    return std.fs.path.join(allocator, &.{ repo_root, links_root, links_file_name });
}

/// Directory for a registered node type (abstract or concrete).
///
/// Abstract `req` → `nodes/req`. Concrete `sys` extending `req` → `nodes/req/sys`.
/// Standalone concrete `sw` → `nodes/sw`.
///
/// Parameters:
/// - `allocator`: Used for the returned path.
/// - `reg`: Loaded registry.
/// - `type_name`: Registry node `type` field.
///
/// Returns: owned relative path from repo root; caller must free.
/// On failure: `error.UnknownNodeType`.
pub fn nodeTypeDir(
    allocator: std.mem.Allocator,
    reg: *const fits_registry.Registry,
    type_name: []const u8,
) ![]const u8 {
    const idx = fits_registry.findNodeTypeIndex(reg.node_types.items, type_name) orelse return error.UnknownNodeType;
    const entry = reg.node_types.items[idx];
    return nodeTypeDirFromFields(allocator, type_name, entry.abstract, entry.extends);
}

/// Parent directory for node instances of a concrete type (same as [`nodeTypeDir`] for that type).
///
/// Parameters:
/// - `allocator`: Used for the returned path.
/// - `reg`: Loaded registry.
/// - `id_prefix`: Concrete type id prefix (e.g. `REQ`).
///
/// Returns: owned relative path; caller must free.
/// On failure: `error.UnknownIdPrefix` when prefix is unknown or abstract.
pub fn nodeInstanceParent(
    allocator: std.mem.Allocator,
    reg: *const fits_registry.Registry,
    id_prefix: []const u8,
) ![]const u8 {
    const idx = fits_registry.findNodeTypeIndexByIdPrefix(reg.node_types.items, id_prefix) orelse return error.UnknownIdPrefix;
    const entry = reg.node_types.items[idx];
    if (entry.abstract) return error.UnknownIdPrefix;
    return nodeTypeDir(allocator, reg, entry.type);
}

/// Builds the type directory path from registry fields (does not consult the registry).
pub fn nodeTypeDirFromFields(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    abstract: bool,
    extends: ?[]const u8,
) ![]const u8 {
    if (abstract) {
        return std.fs.path.join(allocator, &.{ nodes_root, type_name });
    }
    if (extends) |parent| {
        return std.fs.path.join(allocator, &.{ nodes_root, parent, type_name });
    }
    return std.fs.path.join(allocator, &.{ nodes_root, type_name });
}

/// Per-link-type scaffolding directory (e.g. `links/req_links`).
pub fn linkTypeDir(allocator: std.mem.Allocator, link_type: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ links_root, link_type });
}

/// Optional payload directory for one link instance.
pub fn linkInstanceDir(allocator: std.mem.Allocator, link_type: []const u8, link_id: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ links_root, link_type, link_id });
}

test "nodeTypeDir abstract extended standalone" {
    const alloc = std.testing.allocator;
    var reg: fits_registry.Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerAbstractType("req");
    try reg.registerConcreteType("sys", "req", null);
    try reg.registerConcreteType("sw", null, null);

    const req_dir = try nodeTypeDir(alloc, &reg, "req");
    defer alloc.free(req_dir);
    try std.testing.expectEqualStrings("nodes/req", req_dir);

    const sys_dir = try nodeTypeDir(alloc, &reg, "sys");
    defer alloc.free(sys_dir);
    try std.testing.expectEqualStrings("nodes/req/sys", sys_dir);

    const sw_dir = try nodeTypeDir(alloc, &reg, "sw");
    defer alloc.free(sw_dir);
    try std.testing.expectEqualStrings("nodes/sw", sw_dir);
}

test "nodeInstanceParent and link paths" {
    const alloc = std.testing.allocator;
    var reg: fits_registry.Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerAbstractType("req");
    try reg.registerConcreteType("sys", "req", "SYS");

    const parent = try nodeInstanceParent(alloc, &reg, "SYS");
    defer alloc.free(parent);
    try std.testing.expectEqualStrings("nodes/req/sys", parent);

    const link_type_dir = try linkTypeDir(alloc, "req_links");
    defer alloc.free(link_type_dir);
    try std.testing.expectEqualStrings("links/req_links", link_type_dir);

    const link_inst = try linkInstanceDir(alloc, "req_links", "req_links-1");
    defer alloc.free(link_inst);
    try std.testing.expectEqualStrings("links/req_links/req_links-1", link_inst);

    const index = try linksIndexRel(alloc, ".");
    defer alloc.free(index);
    try std.testing.expectEqualStrings("links/links.jsonc", index);
}
