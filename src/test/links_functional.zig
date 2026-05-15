//! Functional tests for [`links_index`](../adapters/fs/links_index.zig): JSONC stripping and structural load.

const std = @import("std");
const links_index = @import("../adapters/fs/links_index.zig");
const links_validate = @import("../adapters/fs/links_validate.zig");

test "relations links.jsonc with line comment passes structural validation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/relations");

    const body = try std.fmt.allocPrint(alloc,
        \\{{
        \\  // optional comment
        \\  "description": "{s}",
        \\  "version": 1,
        \\  "kind": "{s}",
        \\  "links": []
        \\}}
    , .{ links_validate.links_description, links_validate.links_kind });
    defer alloc.free(body);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/relations/links.jsonc", .data = body });

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    var rep = links_validate.ValidationReport{ .allocator = alloc };
    defer rep.deinit();

    var loaded = try links_index.loadLinksStructuralOnly(alloc, std.testing.io, repo_abs, &rep);
    defer loaded.deinit();

    try std.testing.expect(rep.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), loaded.rows().len);
}
