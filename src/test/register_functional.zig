//! Functional tests for [`register`](../app/register.zig) use-cases.

const std = @import("std");
const register = @import("../app/register.zig");
const new_node = @import("../app/new_node.zig");

test "register rename renames managed instance and updates registry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try new_node.run(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", .{});

    try register.runRename(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", "FOO");

    const old_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(old_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, old_path, .{}));

    const new_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "FOO-1" });
    defer alloc.free(new_path);
    const new_st = try tmp.dir.statFile(std.testing.io, new_path, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, new_st.kind);

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"obj_prefix\": \"FOO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"obj_prefix\": \"REQ\"") == null);
}

test "register rename skips out-of-range instance" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "repo/objects");
    try tmp.dir.createDirPath(std.testing.io, "repo/objects/REQ-999");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try register.runRename(alloc, std.testing.io, repo_abs, new_node.default_objects_dir, "REQ", "FOO");

    const orphan = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-999" });
    defer alloc.free(orphan);
    _ = try tmp.dir.statFile(std.testing.io, orphan, .{});

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"obj_prefix\": \"FOO\"") != null);
}

test "register list loads without error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try register.runList(alloc, std.testing.io, repo_abs);
}

test "register link-type records endpoints in registry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runObjType(alloc, std.testing.io, repo_abs, "REQ", false);
    try register.runObjType(alloc, std.testing.io, repo_abs, "DOC", false);
    try register.runLinkType(alloc, std.testing.io, repo_abs, "implements", "REQ", "DOC", false);

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"link_type\": \"implements\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"in_obj_prefix\": \"REQ\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"out_obj_prefix\": \"DOC\"") != null);
}
