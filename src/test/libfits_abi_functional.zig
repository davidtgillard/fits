//! Functional tests for libfits Zig API and JSON helpers.

const std = @import("std");
const libfits = @import("../libfits.zig");
const init_repo = @import("../app/init_repo.zig");
const register_mod = @import("../app/register.zig");

const no_interactive: init_repo.InitOptions = .{ .no_interactive = true };

test "FitsRepo validate empty initialized repo" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);
    try register_mod.registerReqDocFixture(alloc, std.testing.io, repo_abs);

    const repo = try libfits.FitsRepo.open(alloc, std.testing.io, .{ .repo_root = repo_abs });
    defer repo.close();

    const rep = try repo.validate(.{});
    defer {
        for (rep.findings) |f| alloc.free(f.message);
        alloc.free(rep.findings);
    }
    try std.testing.expectEqual(@as(usize, 0), rep.summary.error_count);
}
