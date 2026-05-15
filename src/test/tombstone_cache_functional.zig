//! Functional tests for [`tombstone_cache`](../adapters/cache/tombstone_cache.zig).

const std = @import("std");
const tombstone_cache = @import("../adapters/cache/tombstone_cache.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");

test "putTombstone and sync roundtrip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const sha = "a1b2c3d4e5f6789012345678901234567890abcd";
    try tombstone_cache.putTombstone(alloc, std.testing.io, repo_abs, "REQ-1", .{
        .git_commit = sha,
    });

    var reg: fits_registry.Registry = .{ .allocator = alloc };
    defer reg.deinit();
    try reg.registerNewPrefix("REQ");
    try reg.tombstoneNumeric("REQ", 1, .{ .git_commit = sha });
    try tombstone_cache.syncFromRegistry(alloc, std.testing.io, repo_abs, &reg);

    const path = try std.fs.path.join(alloc, &.{ "repo", ".fits", "tombstone_cache.json" });
    defer alloc.free(path);
    const text = try tmp.dir.readFileAlloc(std.testing.io, path, alloc, .unlimited);
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "REQ-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, sha) != null);
}
