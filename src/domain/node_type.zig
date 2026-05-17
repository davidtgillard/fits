//! Node type resolution: abstract types, concrete types with `extends`, and link endpoint matching.

const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");

/// Returns the concrete [`fits_registry.Registry.NodeTypeEntry`] for `id_prefix`, or null.
pub fn findConcreteByIdPrefix(reg: *const fits_registry.Registry, id_prefix: []const u8) ?*const fits_registry.Registry.NodeTypeEntry {
    const idx = fits_registry.findNodeTypeIndexByIdPrefix(reg.node_types.items, id_prefix) orelse return null;
    const entry = &reg.node_types.items[idx];
    if (entry.abstract) return null;
    return entry;
}

/// Returns whether a node id prefix satisfies a registered link endpoint type name.
///
/// When `endpoint_type` is abstract, any concrete with `extends == endpoint_type` matches.
/// When `endpoint_type` is concrete, the instance prefix must belong to that type only.
pub fn endpointMatchesType(
    reg: *const fits_registry.Registry,
    id_prefix: []const u8,
    endpoint_type: []const u8,
) bool {
    const concrete = findConcreteByIdPrefix(reg, id_prefix) orelse return false;
    const endpoint_idx = fits_registry.findNodeTypeIndex(reg.node_types.items, endpoint_type) orelse return false;
    const endpoint = &reg.node_types.items[endpoint_idx];

    if (endpoint.abstract) {
        const parent = concrete.extends orelse return false;
        return std.mem.eql(u8, parent, endpoint_type);
    }

    return std.mem.eql(u8, concrete.type, endpoint_type);
}
