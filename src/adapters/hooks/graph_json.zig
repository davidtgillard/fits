//! Serialize a [`graph.GraphSnapshot`] as the hook-protocol `graph` JSON object (`nodes` + `edges`).
//! Shared by hook stdin requests and `fits output-graph`.

const std = @import("std");
const graph = @import("../../domain/graph.zig");

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Controls JSON whitespace when emitting graph JSON.
pub const FormatOptions = struct {
    /// When true, indent with two spaces; otherwise minified on one line.
    pretty_print: bool = false,
};

fn edgeKindTag(kind: graph.EdgeKind) []const u8 {
    return switch (kind) {
        .references => "references",
        .registered_link => "registered_link",
    };
}

/// Fills `graph_o` with `nodes` and `edges` arrays for `snapshot`.
///
/// Parameters:
/// - `allocator`: Arena or heap used for JSON object nodes.
/// - `graph_o`: Empty object map; receives `nodes` and `edges` keys.
/// - `snapshot`: Full or bounded graph view to serialize.
pub fn appendGraphObject(
    allocator: std.mem.Allocator,
    graph_o: *ObjectMap,
    snapshot: *const graph.GraphSnapshot,
) !void {
    var nodes_a = std.json.Array.init(allocator);
    for (snapshot.nodes) |n| {
        var no: ObjectMap = .empty;
        try no.put(allocator, "id", .{ .string = n.id });
        try nodes_a.append(.{ .object = no });
    }
    var edges_a = std.json.Array.init(allocator);
    for (snapshot.edges) |e| {
        var eo: ObjectMap = .empty;
        try eo.put(allocator, "from_id", .{ .string = e.from_id });
        try eo.put(allocator, "to_id", .{ .string = e.to_id });
        try eo.put(allocator, "kind", .{ .string = edgeKindTag(e.kind) });
        try eo.put(allocator, "link_type", .{ .string = e.link_type });
        try edges_a.append(.{ .object = eo });
    }
    try graph_o.put(allocator, "nodes", .{ .array = nodes_a });
    try graph_o.put(allocator, "edges", .{ .array = edges_a });
}

/// Allocates UTF-8 JSON for the hook `graph` object shape.
///
/// Parameters:
/// - `allocator`: Owns the returned slice.
/// - `snapshot`: Graph to emit.
/// - `options`: [`FormatOptions`] for minified vs indented output.
///
/// Returns: owned JSON text; caller must `allocator.free` it.
pub fn graphSnapshotJson(
    allocator: std.mem.Allocator,
    snapshot: *const graph.GraphSnapshot,
    options: FormatOptions,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var graph_o: ObjectMap = .empty;
    try appendGraphObject(a, &graph_o, snapshot);

    const root_val = JsonValue{ .object = graph_o };
    const stringify_opts: std.json.Stringify.Options = if (options.pretty_print)
        .{ .whitespace = .indent_2 }
    else
        .{};
    return std.json.Stringify.valueAlloc(allocator, root_val, stringify_opts);
}

test "graph snapshot json round trip" {
    const alloc = std.testing.allocator;

    const nodes = [_]graph.GraphNode{
        .{ .id = "A-1" },
        .{ .id = "B-1" },
    };
    const edges = [_]graph.GraphEdge{
        .{
            .from_id = "A-1",
            .to_id = "B-1",
            .kind = .registered_link,
            .link_type = "rel",
        },
    };
    const snap: graph.GraphSnapshot = .{
        .nodes = &nodes,
        .edges = &edges,
    };

    const text = try graphSnapshotJson(alloc, &snap, .{});
    defer alloc.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const obj = parsed.value.object;
    const ns = obj.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 2), ns.items.len);
    try std.testing.expectEqualStrings("A-1", ns.items[0].object.get("id").?.string);
    const es = obj.get("edges").?.array;
    try std.testing.expectEqual(@as(usize, 1), es.items.len);
    try std.testing.expectEqualStrings("registered_link", es.items[0].object.get("kind").?.string);
}
