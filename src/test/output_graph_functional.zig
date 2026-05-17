//! Functional tests for [`output_graph`](../app/output_graph.zig).

const std = @import("std");
const init_repo = @import("../app/init_repo.zig");
const register = @import("../app/register.zig");
const new_node = @import("../app/new_node.zig");
const new_link = @import("../app/new_link.zig");
const output_graph = @import("../app/output_graph.zig");
const graph_json = @import("../adapters/hooks/graph_json.zig");
const graph_subgraph = @import("../domain/graph_subgraph.zig");
const persona = @import("../cli/persona.zig");

const no_interactive: init_repo.InitOptions = .{ .no_interactive = true };

test "output graph json lists nodes and registered link edge" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);
    try register.registerReqBugFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "req", "req", false);
    const with_md: new_node.NewOptions = .{ .markdown = true };
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", with_md);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", with_md);
    try new_link.run(alloc, std.testing.io, repo_abs, "refs", "REQ-1", "BUG-1");

    const resolved = persona.defaultPersona(alloc);

    var loaded = try output_graph.loadGraph(&resolved, alloc, std.testing.io, repo_abs);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.bundles.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.snapshot.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.snapshot.edges.len);

    const json = try graph_json.graphSnapshotJson(alloc, &loaded.snapshot, .{});
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const nodes = parsed.value.object.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);

    const node_ids = try collectNodeIds(alloc, nodes);
    defer alloc.free(node_ids);
    try std.testing.expect(containsId(node_ids, "BUG-1"));
    try std.testing.expect(containsId(node_ids, "REQ-1"));

    const edges = parsed.value.object.get("edges").?.array;
    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    const edge = edges.items[0].object;
    try std.testing.expectEqualStrings("BUG-1", edge.get("from_id").?.string);
    try std.testing.expectEqualStrings("REQ-1", edge.get("to_id").?.string);
    try std.testing.expectEqualStrings("registered_link", edge.get("kind").?.string);
    try std.testing.expectEqualStrings("refs", edge.get("link_type").?.string);
}

test "pretty print adds indentation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);

    const resolved = persona.defaultPersona(alloc);

    var loaded = try output_graph.loadGraph(&resolved, alloc, std.testing.io, repo_abs);
    defer loaded.deinit(alloc);

    const compact = try graph_json.graphSnapshotJson(alloc, &loaded.snapshot, .{});
    defer alloc.free(compact);
    const pretty = try graph_json.graphSnapshotJson(alloc, &loaded.snapshot, .{ .pretty_print = true });
    defer alloc.free(pretty);

    try std.testing.expect(pretty.len > compact.len);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\n") != null);
}

test "full snapshot graph equivalent to hook incident subgraph with all node seeds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);
    try register.registerReqBugFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "req", "req", false);
    const with_md: new_node.NewOptions = .{ .markdown = true };
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", with_md);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", with_md);
    try new_link.run(alloc, std.testing.io, repo_abs, "refs", "REQ-1", "BUG-1");

    const resolved = persona.defaultPersona(alloc);

    var loaded = try output_graph.loadGraph(&resolved, alloc, std.testing.io, repo_abs);
    defer loaded.deinit(alloc);
    const full = loaded.snapshot;

    var seeds = try alloc.alloc([]const u8, full.nodes.len);
    defer alloc.free(seeds);
    for (full.nodes, 0..) |n, i| seeds[i] = n.id;

    var sub = try graph_subgraph.extractIncidentSubgraph(alloc, &full, .{
        .node_ids = seeds,
        .extra_ids = &.{},
    }, .{});
    defer sub.deinit(alloc);

    const full_json = try graph_json.graphSnapshotJson(alloc, &full, .{});
    defer alloc.free(full_json);
    const sub_json = try graph_json.graphSnapshotJson(alloc, &sub, .{});
    defer alloc.free(sub_json);

    try expectGraphJsonEquivalent(alloc, full_json, sub_json);
}

fn containsId(ids: []const []const u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

fn collectNodeIds(allocator: std.mem.Allocator, nodes: std.json.Array) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, nodes.items.len);
    for (nodes.items, 0..) |item, i| {
        out[i] = item.object.get("id").?.string;
    }
    return out;
}

fn expectGraphJsonEquivalent(allocator: std.mem.Allocator, a_text: []const u8, b_text: []const u8) !void {
    var a_parsed = try std.json.parseFromSlice(std.json.Value, allocator, a_text, .{ .allocate = .alloc_always });
    defer a_parsed.deinit();
    var b_parsed = try std.json.parseFromSlice(std.json.Value, allocator, b_text, .{ .allocate = .alloc_always });
    defer b_parsed.deinit();

    const a_nodes = a_parsed.value.object.get("nodes").?.array;
    const b_nodes = b_parsed.value.object.get("nodes").?.array;
    try std.testing.expectEqual(a_nodes.items.len, b_nodes.items.len);

    const a_node_ids = try collectNodeIds(allocator, a_nodes);
    defer allocator.free(a_node_ids);
    const b_node_ids = try collectNodeIds(allocator, b_nodes);
    defer allocator.free(b_node_ids);

    const a_sorted = try allocator.dupe([]const u8, a_node_ids);
    defer allocator.free(a_sorted);
    const b_sorted = try allocator.dupe([]const u8, b_node_ids);
    defer allocator.free(b_sorted);
    std.mem.sortUnstable([]const u8, a_sorted, {}, stringLess);
    std.mem.sortUnstable([]const u8, b_sorted, {}, stringLess);
    for (a_sorted, b_sorted) |aid, bid| try std.testing.expectEqualStrings(aid, bid);

    const a_edges = a_parsed.value.object.get("edges").?.array;
    const b_edges = b_parsed.value.object.get("edges").?.array;
    try std.testing.expectEqual(a_edges.items.len, b_edges.items.len);

    for (a_edges.items) |ae| {
        const ao = ae.object;
        var found = false;
        for (b_edges.items) |be| {
            const bo = be.object;
            if (std.mem.eql(u8, ao.get("from_id").?.string, bo.get("from_id").?.string) and
                std.mem.eql(u8, ao.get("to_id").?.string, bo.get("to_id").?.string) and
                std.mem.eql(u8, ao.get("kind").?.string, bo.get("kind").?.string) and
                std.mem.eql(u8, ao.get("link_type").?.string, bo.get("link_type").?.string))
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

fn stringLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
