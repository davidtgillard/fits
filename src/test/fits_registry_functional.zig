//! Functional tests for [`Registry`](../adapters/fs/fits_registry.zig): temp directories, real I/O, and JSON on disk.
//! Keeps heavy scenarios out of the adapter module so production code stays focused.

const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");

const Registry = fits_registry.Registry;

test "load merges duplicate prefix with max next (v1 slug field)" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [
        \\    { "slug": "REQ", "next": 3 },
        \\    { "slug": "REQ", "next": 7 }
        \\  ]
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "regtest_repo/.fits");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "regtest_repo/.fits/registry.json", .data = json });

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "regtest_repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    var reg = try Registry.load(alloc, std.testing.io, repo_abs);
    defer reg.deinit();

    try std.testing.expectEqual(@as(u64, 7), try reg.allocateNextNumeric("REQ"));
}

test "save and load roundtrip writes v2 obj_prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    {
        var reg: Registry = .{ .allocator = alloc };
        defer reg.deinit();
        try reg.registerNewPrefix("Z");
        _ = try reg.allocateNextNumeric("Z");
        try reg.save(std.testing.io, repo_abs);
    }

    var reg2 = try Registry.load(alloc, std.testing.io, repo_abs);
    defer reg2.deinit();
    try std.testing.expectEqual(@as(u64, 2), try reg2.allocateNextNumeric("Z"));

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"obj_prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"version\": 2") != null);
}
