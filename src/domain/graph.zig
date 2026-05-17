//! Pure domain types for node snapshots and an immutable graph view.
//! In fits vocabulary, a **graph object** is either a **node** (versioned dataset instance under type-scoped `nodes/…`)
//! or a **link** (edge instance from `links/links.jsonc`). This module models nodes and their incident graph shape only.
//! No filesystem or I/O: adapters build these values from disk.

const std = @import("std");

/// Stable logical identifier for a graph node (not a host path).
pub const NodeId = []const u8;

/// One file inside a node folder, addressed by path relative to that folder.
pub const NodeFile = struct {
    /// Path relative to the node root, using POSIX separators.
    relative_path: []const u8,
    /// Raw file bytes as read from the working tree.
    contents: []const u8,
};

/// Snapshot of one node's folder: id plus all contained files.
pub const NodeBundle = struct {
    /// Logical id for this node.
    id: NodeId,
    /// Files belonging to the node; order is meaningful for hashing and tests.
    files: []const NodeFile,
};

/// Borrowed trio describing one registered link for [`graph_builder.buildDeterministicSnapshot`].
pub const LinkEdgeInput = struct {
    /// Registered link type name.
    link_type: []const u8,
    /// `OUT` node id.
    out_id: []const u8,
    /// `IN` node id.
    in_id: []const u8,
};

/// Kind of directed relationship between two nodes in the graph.
pub const EdgeKind = enum {
    /// Target node is referenced by or depended on by the source (legacy placeholder).
    references,
    /// Registered link type from [`links/links.jsonc`]; see [`GraphEdge.link_type`].
    registered_link,
};

/// One vertex in the graph snapshot (a node instance).
pub const GraphNode = struct {
    /// Node id this vertex represents.
    id: NodeId,
};

/// Directed edge between two nodes.
pub const GraphEdge = struct {
    /// Source node id (`OUT` endpoint for registered links).
    from_id: NodeId,
    /// Target node id (`IN` endpoint for registered links).
    to_id: NodeId,
    /// Relationship semantics.
    kind: EdgeKind,
    /// When `kind` is [`.registered_link`], the registered name (e.g. `implements`); otherwise empty.
    link_type: []const u8,
};

/// Immutable graph over nodes: vertices and edges in deterministic order.
pub const GraphSnapshot = struct {
    /// Nodes in stable, deterministic order (e.g. sorted by id).
    nodes: []const GraphNode,
    /// Edges in stable, deterministic order (e.g. sorted by from, to, kind).
    edges: []const GraphEdge,

    /// Frees heap memory owned by this snapshot's top-level slices.
    ///
    /// Parameters:
    /// - `self`: Snapshot whose `nodes` and `edges` slices were allocated with `allocator`.
    /// - `allocator`: Same allocator used to allocate `nodes` and `edges`.
    ///
    /// Returns: nothing. Does not free memory pointed to by ids or paths inside nodes.
    /// For [`.registered_link`] edges, [`GraphEdge.link_type`] is not freed here when it aliases
    /// loader-owned buffers; callers that allocated `link_type` per edge must free those separately.
    pub fn deinit(self: GraphSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.edges);
    }
};
