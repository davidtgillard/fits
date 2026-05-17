//! Functional tests for [`init_repo`](../app/init_repo.zig).

const std = @import("std");
const init_repo = @import("../app/init_repo.zig");

test "init creates registry links config and latticedb" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs);

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const reg_contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(reg_contents);
    try std.testing.expect(std.mem.indexOf(u8, reg_contents, "\"node_types\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg_contents, "\"link_types\": []") != null);

    const links_sub = try std.fs.path.join(alloc, &.{ "repo", "relations", "links.jsonc" });
    defer alloc.free(links_sub);
    const links_contents = try tmp.dir.readFileAlloc(std.testing.io, links_sub, alloc, .unlimited);
    defer alloc.free(links_contents);
    try std.testing.expect(std.mem.indexOf(u8, links_contents, "\"links\": []") != null);

    const cfg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "fits_config.toml" });
    defer alloc.free(cfg_sub);
    const cfg_contents = try tmp.dir.readFileAlloc(std.testing.io, cfg_sub, alloc, .unlimited);
    defer alloc.free(cfg_contents);
    try std.testing.expect(std.mem.indexOf(u8, cfg_contents, "update_check_time_period = 86400") != null);

    const ldb_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "latticedb" });
    defer alloc.free(ldb_sub);
    const ldb_st = try tmp.dir.statFile(std.testing.io, ldb_sub, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, ldb_st.kind);
}

test "init twice returns AlreadyInitialized" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs);
    try std.testing.expectError(error.AlreadyInitialized, init_repo.run(alloc, std.testing.io, repo_abs));
}
