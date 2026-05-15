//! Functional tests for [`run`](../app/new_object.zig): creates paths on disk and updates the registry.

const std = @import("std");
const new_object = @import("../app/new_object.zig");
const register = @import("../app/register.zig");

test "new object creates objects dir and registry entry when prefix registered" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{});

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    var reg_file = try tmp.dir.openFile(std.testing.io, reg_sub, .{});
    defer reg_file.close(std.testing.io);
    const reg_st = try reg_file.stat(std.testing.io);
    try std.testing.expect(reg_st.size > 0);

    const obj_sub = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(obj_sub);
    const obj_st = try tmp.dir.statFile(std.testing.io, obj_sub, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, obj_st.kind);
}

test "new object fails without registered prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try std.testing.expectError(error.UnknownObjPrefix, new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{}));
}
