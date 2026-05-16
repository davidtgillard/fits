//! Functional tests for [`run`](../app/new_link.zig): persists a link row and advances the registry link counter.

const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const new_link = @import("../app/new_link.zig");
const new_node = @import("../app/new_node.zig");
const register = @import("../app/register.zig");

test "new link appends links.jsonc row and consumes link id from registry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runObjType(alloc, std.testing.io, repo_abs, "REQ", false);
    try register.runObjType(alloc, std.testing.io, repo_abs, "BUG", false);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "REQ", "BUG", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", .{});

    try new_link.run(alloc, std.testing.io, repo_abs, "refs", "REQ-1", "BUG-1");

    const path = try std.fs.path.join(alloc, &.{ "repo", "relations", "links.jsonc" });
    defer alloc.free(path);
    const raw = try tmp.dir.readFileAlloc(std.testing.io, path, alloc, .unlimited);
    defer alloc.free(raw);

    try std.testing.expect(std.mem.indexOf(u8, raw, "\"refs-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"REQ-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"BUG-1\"") != null);

    var reg = try fits_registry.Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg.deinit();
    try std.testing.expectEqual(@as(u64, 2), reg.nextForLinkType("refs").?);
}

test "new link fails for unknown link type" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runObjType(alloc, std.testing.io, repo_abs, "REQ", false);
    try register.runObjType(alloc, std.testing.io, repo_abs, "BUG", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", .{});

    try std.testing.expectError(error.UnknownLinkType, new_link.run(alloc, std.testing.io, repo_abs, "norefs", "REQ-1", "BUG-1"));
}

test "new link rejects endpoints that do not match registry in/out prefixes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runObjType(alloc, std.testing.io, repo_abs, "REQ", false);
    try register.runObjType(alloc, std.testing.io, repo_abs, "BUG", false);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "refs", "REQ", "BUG", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "BUG", .{});

    try std.testing.expectError(error.LinkEndpointsMismatchRegistry, new_link.run(alloc, std.testing.io, repo_abs, "refs", "BUG-1", "REQ-1"));
}
