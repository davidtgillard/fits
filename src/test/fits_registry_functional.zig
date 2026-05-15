//! Functional tests for [`Registry`](../adapters/fs/fits_registry.zig): temp directories, real I/O, and JSON on disk.
//! Keeps heavy scenarios out of the adapter module so production code stays focused.

const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const registry_validate = @import("../adapters/fs/registry_validate.zig");

const Registry = fits_registry.Registry;

test "load rejects invalid registry with RegistryInvalid" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [{ "obj_prefix": "BAD-PREFIX", "next": 0 }]
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "bad_repo/.fits");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad_repo/.fits/registry.json", .data = json });

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "bad_repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    var validation_report: registry_validate.ValidationReport = undefined;
    try std.testing.expectError(error.RegistryInvalid, Registry.load(alloc, std.testing.io, repo_abs, &validation_report));
    defer validation_report.deinit();
    try std.testing.expect(validation_report.issues.items.len >= 2);
}

test "load merges duplicate prefix with max next" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [
        \\    { "obj_prefix": "REQ", "next": 3 },
        \\    { "obj_prefix": "REQ", "next": 7 }
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

    var reg = try Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg.deinit();

    try std.testing.expectEqual(@as(u64, 7), try reg.allocateNextNumeric("REQ"));
}

test "save and load roundtrip writes obj_prefix" {
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

    var reg2 = try Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg2.deinit();
    try std.testing.expectEqual(@as(u64, 2), try reg2.allocateNextNumeric("Z"));

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"description\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, registry_validate.registry_description) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"obj_prefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"version\": 1") != null);
}

test "tombstone with git_commit roundtrip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const sha = "a1b2c3d4e5f6789012345678901234567890abcd";

    {
        var reg: Registry = .{ .allocator = alloc };
        defer reg.deinit();
        try reg.registerNewPrefix("REQ");
        try reg.tombstoneNumeric("REQ", 1, .{ .git_commit = sha });
        try reg.tombstoneNumeric("REQ", 2, .{});
        try reg.save(std.testing.io, repo_abs);
    }

    var reg2 = try Registry.load(alloc, std.testing.io, repo_abs, null);
    defer reg2.deinit();
    try std.testing.expect(reg2.isTombstoned("REQ", 1));
    try std.testing.expect(reg2.isTombstoned("REQ", 2));
    const ts1 = reg2.prefixes.items[0].tombstones.items[0];
    try std.testing.expectEqualStrings(sha, ts1.git_commit.?);
    try std.testing.expectEqual(@as(?[]const u8, null), reg2.prefixes.items[0].tombstones.items[1].git_commit);

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"git_commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"tombstones\"") != null);
}
