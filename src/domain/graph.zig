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

/// Kind of directed relationship between two objects in the graph.
pub const EdgeKind = enum {
    /// Target object is referenced by or depended on by the source.
    references,
};

/// One node in the object graph.
pub const GraphNode = struct {
    /// Object this node represents.
    id: ObjectId,
};

/// Directed edge between two objects.
pub const GraphEdge = struct {
    /// Source object id.
    from_id: ObjectId,
    /// Target object id.
    to_id: ObjectId,
    /// Relationship semantics.
    kind: EdgeKind,
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
    /// Returns: nothing. Does not free memory pointed to by ids or paths inside nodes/edges.
    pub fn deinit(self: GraphSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.edges);
    }
};
