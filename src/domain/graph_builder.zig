//! Builds a [`GraphSnapshot`](graph.GraphSnapshot) from [`ObjectBundle`](graph.ObjectBundle) slices.
//! Graph construction is pure: no filesystem access.

const std = @import("std");
const graph = @import("graph.zig");

/// Errors produced while constructing a graph from bundles.
pub const BuildError = error{
    /// Two bundles claimed the same `ObjectId`.
    DuplicateObjectId,
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
        /// - `bundles`: Normalized object bundles to include as graph input.
        ///
        /// Returns: a [`graph.GraphSnapshot`] on success. On failure, returns an arbitrary error from the implementation.
        build: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bundles: []const graph.ObjectBundle,
        ) anyerror!graph.GraphSnapshot,
    };

    /// Invokes the configured implementation to build a graph.
    ///
    /// Parameters:
    /// - `self`: Type-erased builder.
    /// - `allocator`: Passed through to the implementation.
    /// - `bundles`: Object bundles to turn into a graph snapshot.
    ///
    /// Returns: a [`graph.GraphSnapshot`] on success, or the same error as the underlying `build` implementation.
    pub fn build(
        self: GraphBuilder,
        allocator: std.mem.Allocator,
        bundles: []const graph.ObjectBundle,
    ) !graph.GraphSnapshot {
        return self.vtable.build(self.context, allocator, bundles);
    }
};

/// Default builder: one node per bundle, duplicate ids rejected, no edges yet.
pub const DeterministicGraphBuilder = struct {
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

    // Vtable trampoline: forwards to `buildDeterministicSnapshot`.
    fn buildAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        bundles: []const graph.ObjectBundle,
    ) anyerror!graph.GraphSnapshot {
        const self: *DeterministicGraphBuilder = @ptrCast(@alignCast(context));
        _ = self;
        return buildDeterministicSnapshot(allocator, bundles);
    }
};

/// Allocates a snapshot with one node per bundle (sorted input recommended), empty edges.
///
/// Parameters:
/// - `allocator`: Used for the `nodes` and `edges` slices and temporary duplicate detection.
/// - `bundles`: One graph node per element; each `bundle.id` must be unique.
///
/// Returns: a [`graph.GraphSnapshot`] with `nodes.len == bundles.len` and `edges.len == 0` on success.
/// On failure: `error.OutOfMemory` from allocation, or [`BuildError.DuplicateObjectId`] if ids repeat.
/// Caller must free with [`graph.GraphSnapshot.deinit`].
pub fn buildDeterministicSnapshot(
    allocator: std.mem.Allocator,
    bundles: []const graph.ObjectBundle,
) !graph.GraphSnapshot {
    var nodes = try allocator.alloc(graph.GraphNode, bundles.len);
    errdefer allocator.free(nodes);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (bundles, 0..) |bundle, idx| {
        if (try seen.fetchPut(bundle.id, {})) |_| {
            return BuildError.DuplicateObjectId;
        }
        nodes[idx] = .{ .id = bundle.id };
    }

    // Edge derivation and cycle policy are intentionally deferred.
    const edges = try allocator.alloc(graph.GraphEdge, 0);
    return .{
        .nodes = nodes,
        .edges = edges,
    };
}
