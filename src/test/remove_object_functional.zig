//! Functional tests for [`remove_object`](../app/remove_object.zig).

const std = @import("std");
const remove_object = @import("../app/remove_object.zig");
const register = @import("../app/register.zig");
const new_object = @import("../app/new_object.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");

fn initGitRepo(alloc: std.mem.Allocator, io: std.Io, repo_abs: []const u8) !void {
    try runGit(alloc, io, &.{ "git", "-C", repo_abs, "init" });
    try runGit(alloc, io, &.{ "git", "-C", repo_abs, "config", "user.email", "fits@test.local" });
    try runGit(alloc, io, &.{ "git", "-C", repo_abs, "config", "user.name", "fits test" });
}

fn runGit(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io, .{ .argv = argv });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}

test "rm without git tombstones n only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{});

    try remove_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ-1");

    const obj_path = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-1" });
    defer alloc.free(obj_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, obj_path, .{}));

    var reg = try fits_registry.Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg.deinit();
    try std.testing.expect(reg.isTombstoned("REQ", 1));
    try std.testing.expectEqual(@as(?[]const u8, null), reg.prefixes.items[0].tombstones.items[0].git_commit);

    try new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{});
    const obj2 = try std.fs.path.join(alloc, &.{ "repo", "objects", "REQ-2" });
    defer alloc.free(obj2);
    _ = try tmp.dir.statFile(std.testing.io, obj2, .{});
}

test "rm with git sets git_commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try initGitRepo(alloc, std.testing.io, repo_abs);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    // Use markdown so git tracks a file (empty directories are not versioned).
    try new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{ .markdown = true });

    try runGit(alloc, std.testing.io, &.{ "git", "-C", repo_abs, "add", "-A" });
    try runGit(alloc, std.testing.io, &.{ "git", "-C", repo_abs, "commit", "-m", "init" });

    try remove_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ-1");

    var reg = try fits_registry.Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg.deinit();
    const ts = reg.prefixes.items[0].tombstones.items[0];
    try std.testing.expect(ts.git_commit != null);
    try std.testing.expectEqual(@as(usize, fits_registry.git_commit_hex_len), ts.git_commit.?.len);

    const cache_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "tombstone_cache.json" });
    defer alloc.free(cache_sub);
    const cache_text = try tmp.dir.readFileAlloc(std.testing.io, cache_sub, alloc, .unlimited);
    defer alloc.free(cache_text);
    try std.testing.expect(std.mem.indexOf(u8, cache_text, "\"git_commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cache_text, "REQ-1") != null);
}

test "rm twice errors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try register.runNew(alloc, std.testing.io, repo_abs, "REQ");
    try new_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ", .{});

    try remove_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ-1");
    try std.testing.expectError(error.AlreadyTombstoned, remove_object.run(alloc, std.testing.io, repo_abs, new_object.default_objects_dir, "REQ-1"));
}
