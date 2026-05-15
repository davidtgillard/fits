//! Pure domain types for object snapshots and an immutable graph view.
//! No filesystem or I/O: adapters build these values from disk.

const std = @import("std");

/// Stable logical identifier for a dataset object (not a host path).
pub const ObjectId = []const u8;

/// One file inside an object folder, addressed by path relative to that folder.
pub const ObjectFile = struct {
    /// Path relative to the object root, using POSIX separators.
    relative_path: []const u8,
    /// Raw file bytes as read from the working tree.
    contents: []const u8,
};

/// Snapshot of one object's folder: id plus all contained files.
pub const ObjectBundle = struct {
    /// Logical id for this object.
    id: ObjectId,
    /// Files belonging to the object; order is meaningful for hashing and tests.
    files: []const ObjectFile,
};

/// Borrowed trio describing one registered link for [`graph_builder.buildDeterministicSnapshot`].
pub const LinkEdgeInput = struct {
    /// Registered link type name.
    link_type: []const u8,
    /// `OUT` object id.
    out_id: []const u8,
    /// `IN` object id.
    in_id: []const u8,
};

/// Kind of directed relationship between two objects in the graph.
pub const EdgeKind = enum {
    /// Target object is referenced by or depended on by the source (legacy placeholder).
    references,
    /// Registered link type from [`relations/links.jsonc`]; see [`GraphEdge.link_type`].
    registered_link,
};

/// One node in the object graph.
pub const GraphNode = struct {
    /// Object this node represents.
    id: ObjectId,
};

/// Directed edge between two objects.
pub const GraphEdge = struct {
    /// Source object id (`OUT` endpoint for registered links).
    from_id: ObjectId,
    /// Target object id (`IN` endpoint for registered links).
    to_id: ObjectId,
    /// Relationship semantics.
    kind: EdgeKind,
    /// When `kind` is [`.registered_link`], the registered name (e.g. `implements`); otherwise empty.
    link_type: []const u8,
};

/// Immutable graph over objects: nodes and edges in deterministic order.
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
