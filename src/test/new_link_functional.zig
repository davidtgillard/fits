//! Functional tests for [`new_link`](../app/new_link.zig).

const std = @import("std");
const register = @import("../app/register.zig");
const new_node = @import("../app/new_node.zig");
const new_link = @import("../app/new_link.zig");

test "new link appends row and advances counter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqBugFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "req", "req", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", .{});

    try new_link.run(alloc, std.testing.io, repo_abs, "refs", "REQ-1", "BUG-1");

    const links_sub = try std.fs.path.join(alloc, &.{ "repo", "relations", "links.jsonc" });
    defer alloc.free(links_sub);
    const links_text = try tmp.dir.readFileAlloc(std.testing.io, links_sub, alloc, .unlimited);
    defer alloc.free(links_text);
    try std.testing.expect(std.mem.indexOf(u8, links_text, "\"link_type\": \"refs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, links_text, "\"out\": \"BUG-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, links_text, "\"in\": \"REQ-1\"") != null);
}

test "new link rejects unknown endpoints" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqBugFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "req", "req", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    try std.testing.expectError(error.InvalidObjName, new_link.run(alloc, std.testing.io, repo_abs, "refs", "REQ-1", "MISSING-1"));
}

test "new link rejects endpoints that do not match registry in/out types" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqBugFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "REQ", "BUG", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", .{});

    try std.testing.expectError(error.LinkEndpointsMismatchRegistry, new_link.run(alloc, std.testing.io, repo_abs, "refs", "BUG-1", "REQ-1"));
}
