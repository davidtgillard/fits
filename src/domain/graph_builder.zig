//! Builds a [`GraphSnapshot`](graph.GraphSnapshot) from [`NodeBundle`](graph.NodeBundle) slices.
//! Graph construction is pure: no filesystem access.

const std = @import("std");
const graph = @import("graph.zig");

/// Errors produced while constructing a graph from bundles.
pub const BuildError = error{
    /// Two bundles claimed the same [`graph.NodeId`].
    DuplicateNodeId,
};

/// Strategy object that turns normalized bundles into a graph snapshot.
pub const GraphBuilder = struct {
    /// Opaque implementation state.
    context: *anyopaque,
    /// Virtual method table for the implementation.
    vtable: *const VTable,

    /// Virtual methods for [`GraphBuilder`].
    pub const VTable = struct {
        /// Builds a snapshot; may allocate with `allocator`.
        ///
        /// Parameters:
        /// - `context`: Implementation state (`GraphBuilder.context`).
        /// - `allocator`: Allocator for the output snapshot's slices.
        /// - `bundles`: Normalized node bundles to include as graph input.
        /// - `link_edges`: Borrowed registered links (`OUT`→`IN`); may be empty.
        ///
        /// Returns: a [`graph.GraphSnapshot`] on success. On failure, returns an arbitrary error from the implementation.
        build: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bundles: []const graph.NodeBundle,
            link_edges: []const graph.LinkEdgeInput,
        ) anyerror!graph.GraphSnapshot,
    };

    /// Invokes the configured implementation to build a graph.
    ///
    /// Parameters:
    /// - `self`: Type-erased builder.
    /// - `allocator`: Passed through to the implementation.
    /// - `bundles`: Node bundles to turn into a graph snapshot.
    /// - `link_edges`: Registered links to include as graph edges (may be empty).
    ///
    /// Returns: a [`graph.GraphSnapshot`] on success, or the same error as the underlying `build` implementation.
    pub fn build(
        self: GraphBuilder,
        allocator: std.mem.Allocator,
        bundles: []const graph.NodeBundle,
        link_edges: []const graph.LinkEdgeInput,
    ) !graph.GraphSnapshot {
        return self.vtable.build(self.context, allocator, bundles, link_edges);
    }
};

/// Default builder: one node per bundle, duplicate ids rejected, optional registered-link edges.
pub const DeterministicGraphBuilder = struct {
    // Vtable trampoline: forwards to `buildDeterministicSnapshot`.
    fn buildAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        bundles: []const graph.NodeBundle,
        link_edges: []const graph.LinkEdgeInput,
    ) anyerror!graph.GraphSnapshot {
        _ = context;
        return buildDeterministicSnapshot(allocator, bundles, link_edges);
    }

    /// Wraps this value as a [`GraphBuilder`] for use in orchestration code.
    ///
    /// Parameters:
    /// - `self`: Mutable reference stored as the opaque context of the returned builder.
    ///
    /// Returns: a [`GraphBuilder`] whose virtual calls forward to [`buildDeterministicSnapshot`].
    pub fn asInterface(self: *DeterministicGraphBuilder) GraphBuilder {
        return .{
            .context = self,
            .vtable = &.{
                .build = buildAdapter,
            },
        };
    }
};

/// Allocates a snapshot with one node per bundle (sorted input recommended) and registered-link edges.
///
/// Parameters:
/// - `allocator`: Used for the `nodes` and `edges` slices and temporary duplicate detection.
/// - `bundles`: One graph node per element; each `bundle.id` must be unique.
/// - `link_edges`: Directed edges from `out_id` to `in_id` per [`graph.LinkEdgeInput`].
///
/// Returns: a [`graph.GraphSnapshot`] on success.
/// On failure: `error.OutOfMemory` from allocation, or [`BuildError.DuplicateNodeId`] if bundle ids repeat.
/// Caller must free with [`graph.GraphSnapshot.deinit`].
pub fn buildDeterministicSnapshot(
    allocator: std.mem.Allocator,
    bundles: []const graph.NodeBundle,
    link_edges: []const graph.LinkEdgeInput,
) !graph.GraphSnapshot {
    var nodes = try allocator.alloc(graph.GraphNode, bundles.len);
    errdefer allocator.free(nodes);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (bundles, 0..) |bundle, idx| {
        if (try seen.fetchPut(bundle.id, {})) |_| {
            return BuildError.DuplicateNodeId;
        }
        nodes[idx] = .{ .id = bundle.id };
    }

    var edges = try allocator.alloc(graph.GraphEdge, link_edges.len);
    errdefer allocator.free(edges);

    for (link_edges, 0..) |le, i| {
        edges[i] = .{
            .from_id = le.out_id,
            .to_id = le.in_id,
            .kind = .registered_link,
            .link_type = le.link_type,
        };
    }

    std.mem.sortUnstable(graph.GraphEdge, edges, {}, struct {
        fn less(_: void, a: graph.GraphEdge, b: graph.GraphEdge) bool {
            const oa = std.mem.order(u8, a.from_id, b.from_id);
            if (oa != .eq) return oa == .lt;
            const ob = std.mem.order(u8, a.to_id, b.to_id);
            if (ob != .eq) return ob == .lt;
            return std.mem.order(u8, a.link_type, b.link_type) == .lt;
        }
    }.less);

    return .{
        .nodes = nodes,
        .edges = edges,
    };
}
