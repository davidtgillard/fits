//! Functional tests for [`register_rm`](../app/register_rm.zig).

const std = @import("std");
const register = @import("../app/register.zig");
const register_rm = @import("../app/register_rm.zig");
const new_node = @import("../app/new_node.zig");
const new_link = @import("../app/new_link.zig");
const remove_object = @import("../app/remove_object.zig");
const links_index = @import("../adapters/fs/links_index.zig");

fn registerReq(alloc: std.mem.Allocator, io: std.Io, repo: []const u8) !void {
    try register.runNodeType(alloc, io, repo, "req", .{ .abstract = true });
    try register.runNodeType(alloc, io, repo, "REQ", .{ .extends = "req" });
}

test "register rm empty node type" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);
    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\": \"REQ\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\":\"req\"") != null or std.mem.indexOf(u8, contents, "\"type\": \"req\"") != null);
}

test "register rm node type with instance requires force" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    try std.testing.expectError(error.TypeHasInstances, register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{}));

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\":\"REQ\"") != null or std.mem.indexOf(u8, contents, "\"type\": \"REQ\"") != null);
}

test "register rm node type with force removes instance" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{ .force = true });

    const obj_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(obj_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, obj_path, .{}));
}

test "register rm preserve-local keeps objects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{
        .force = true,
        .preserve_local = true,
    });

    const obj_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(obj_path);
    _ = try tmp.dir.statFile(std.testing.io, obj_path, .{});
}

test "register rm preserve-local without force fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);

    try std.testing.expectError(error.PreserveLocalRequiresForce, register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{
        .preserve_local = true,
    }));
}

test "register rm dangling link requires cascade" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqDocFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "implements", "req", "doc", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "DOC", .{});
    try new_link.run(alloc, std.testing.io, repo_abs, "implements", "REQ-1", "DOC-1");

    try std.testing.expectError(error.CascadeRequired, register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{ .force = true }));
}

test "register rm force cascade removes dangling link and node type" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqDocFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "implements", "req", "doc", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "DOC", .{});
    try new_link.run(alloc, std.testing.io, repo_abs, "implements", "REQ-1", "DOC-1");

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{
        .force = true,
        .cascade = true,
    });

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\": \"REQ\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"link_type\": \"implements\"") == null);

    const links_path = try std.fs.path.join(alloc, &.{ "repo", "relations", "links.jsonc" });
    defer alloc.free(links_path);
    const links_text = try tmp.dir.readFileAlloc(std.testing.io, links_path, alloc, .unlimited);
    defer alloc.free(links_text);
    try std.testing.expect(std.mem.indexOf(u8, links_text, "implements-1") == null);
}

test "register rm force skips tombstoned node filesystem" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try registerReq(alloc, std.testing.io, repo_abs);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try remove_object.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ-1");

    const stray_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(stray_path);
    try tmp.dir.createDirPath(std.testing.io, "repo/objects/REQ-1");

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{ .force = true });

    _ = try tmp.dir.statFile(std.testing.io, stray_path, .{});
}

test "register rm link type with force" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.registerReqDocFixture(alloc, std.testing.io, repo_abs);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "implements", "req", "doc", false);
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "DOC", .{});
    try new_link.run(alloc, std.testing.io, repo_abs, "implements", "REQ-1", "DOC-1");

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "implements", .{ .force = true });

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"link_type\": \"implements\"") == null);

    var rep = @import("../adapters/fs/links_validate.zig").ValidationReport{ .allocator = alloc };
    defer rep.deinit();
    var reg = try @import("../adapters/fs/fits_registry.zig").loadRegistry(alloc, std.testing.io, repo_abs);
    defer reg.deinit();
    var loaded = try links_index.loadLinksStructuralOnly(alloc, std.testing.io, repo_abs, &rep);
    defer loaded.deinit();
    for (loaded.rows()) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.link_type, "implements"));
    }
}

test "register rm abstract with children requires force cascade" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNodeType(alloc, std.testing.io, repo_abs, "req", .{ .abstract = true });
    try register.runNodeType(alloc, std.testing.io, repo_abs, "sys", .{ .extends = "req" });
    try register.runNodeType(alloc, std.testing.io, repo_abs, "cus", .{ .extends = "req" });

    try std.testing.expectError(error.TypeHasChildren, register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "req", .{}));

    try register_rm.runRemoveType(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "req", .{
        .force = true,
        .cascade = true,
    });

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\": \"req\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\": \"sys\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\": \"cus\"") == null);
}
