//! Bounded extraction of an incident subgraph from a [`GraphSnapshot`](graph.zig).
//! Used for hook requests: seeds from work items, one hop along edges, deterministic order.
//! No filesystem: pure filtering on in-memory graph data.

const std = @import("std");
const graph = @import("graph.zig");

/// Host-enforced limits on subgraph size in hook requests.
pub const SubgraphCaps = struct {
    /// Maximum distinct node ids in the result `nodes` slice.
    max_nodes: usize = 10_000,
    /// Maximum edges in the result `edges` slice.
    max_edges: usize = 100_000,
};

/// Seeded by hook `work`: node ids and link endpoint ids to anchor the neighborhood.
pub const SubgraphSeeds = struct {
    /// Node instance ids (e.g. from `work.nodes` in the hook request).
    node_ids: []const []const u8,
    /// Additional ids to treat as seeds (e.g. link `out` / `in` endpoints).
    extra_ids: []const []const u8,
};

/// Result of [`extractIncidentSubgraph`]: caller frees with [`graph.GraphSnapshot.deinit`].
pub const ExtractError = error{
    /// `nodes.len` or `edges.len` would exceed [`SubgraphCaps`].
    SubgraphTooLarge,
} || std.mem.Allocator.Error;

/// One-hop neighborhood: seeds, all edges incident to any seed node, all nodes appearing on those edges.
///
/// Parameters:
/// - `allocator`: Allocates output `nodes` and `edges` slices; does not duplicate string bytes inside [`GraphSnapshot`](graph.zig) (aliases snapshot ids).
/// - `snapshot`: Full graph built by the host (same source of truth as validate).
/// - `seeds`: union of work node ids and link endpoint ids for this batch.
/// - `caps`: hard limits; exceed → [`error.SubgraphTooLarge`].
///
/// Returns: a new [`graph.GraphSnapshot`] referencing the same underlying id bytes as `snapshot`.
pub fn extractIncidentSubgraph(
    allocator: std.mem.Allocator,
    snapshot: *const graph.GraphSnapshot,
    seeds: SubgraphSeeds,
    caps: SubgraphCaps,
) ExtractError!graph.GraphSnapshot {
    var seed_set = std.StringHashMap(void).init(allocator);
    defer seed_set.deinit();
    for (seeds.node_ids) |id| try seed_set.put(id, {});
    for (seeds.extra_ids) |id| try seed_set.put(id, {});

    var edge_pick = std.ArrayListUnmanaged(usize).empty;
    defer edge_pick.deinit(allocator);
    try edge_pick.ensureTotalCapacity(allocator, snapshot.edges.len);

    for (snapshot.edges, 0..) |e, i| {
        const from_seed = seed_set.contains(e.from_id);
        const to_seed = seed_set.contains(e.to_id);
        if (!from_seed and !to_seed) continue;
        if (edge_pick.items.len >= caps.max_edges) return error.SubgraphTooLarge;
        edge_pick.appendAssumeCapacity(i);
    }

    var node_set = std.StringHashMap(void).init(allocator);
    defer node_set.deinit();
    for (seeds.node_ids) |id| try node_set.put(id, {});
    for (seeds.extra_ids) |id| try node_set.put(id, {});

    for (edge_pick.items) |ei| {
        const e = snapshot.edges[ei];
        try node_set.put(e.from_id, {});
        try node_set.put(e.to_id, {});
    }

    if (node_set.count() > caps.max_nodes) return error.SubgraphTooLarge;

    var node_ids = try allocator.alloc([]const u8, node_set.count());
    defer allocator.free(node_ids);
    var ni: usize = 0;
    var it = node_set.keyIterator();
    while (it.next()) |k| {
        node_ids[ni] = k.*;
        ni += 1;
    }
    std.mem.sortUnstable([]const u8, node_ids, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    const nodes = try allocator.alloc(graph.GraphNode, node_ids.len);
    errdefer allocator.free(nodes);
    for (node_ids, 0..) |nid, j| {
        nodes[j] = .{ .id = nid };
    }

    var edges = try allocator.alloc(graph.GraphEdge, edge_pick.items.len);
    errdefer allocator.free(edges);
    for (edge_pick.items, 0..) |ei, j| {
        edges[j] = snapshot.edges[ei];
    }
    std.mem.sortUnstable(graph.GraphEdge, edges, {}, struct {
        fn less(_: void, a: graph.GraphEdge, b: graph.GraphEdge) bool {
            const oa = std.mem.order(u8, a.from_id, b.from_id);
            if (oa != .eq) return oa == .lt;
            const ob = std.mem.order(u8, a.to_id, b.to_id);
            if (ob != .eq) return ob == .lt;
            if (@intFromEnum(a.kind) != @intFromEnum(b.kind)) {
                return @intFromEnum(a.kind) < @intFromEnum(b.kind);
            }
            return std.mem.order(u8, a.link_type, b.link_type) == .lt;
        }
    }.less);

    return .{
        .nodes = nodes,
        .edges = edges,
    };
}

test "incident subgraph one hop" {
    const alloc = std.testing.allocator;

    var nodes = try alloc.alloc(graph.GraphNode, 3);
    nodes[0] = .{ .id = "A-1" };
    nodes[1] = .{ .id = "B-1" };
    nodes[2] = .{ .id = "C-1" };

    var edges = try alloc.alloc(graph.GraphEdge, 1);
    edges[0] = .{
        .from_id = "A-1",
        .to_id = "B-1",
        .kind = .registered_link,
        .link_type = "rel",
    };

    const snap: graph.GraphSnapshot = .{
        .nodes = nodes,
        .edges = edges,
    };
    defer snap.deinit(alloc);

    const seeds: SubgraphSeeds = .{
        .node_ids = &.{"A-1"},
        .extra_ids = &.{},
    };

    var sub = try extractIncidentSubgraph(alloc, &snap, seeds, .{});
    defer sub.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), sub.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), sub.edges.len);
    try std.testing.expectEqualStrings("A-1", sub.nodes[0].id);
    try std.testing.expectEqualStrings("B-1", sub.nodes[1].id);
}
