//! fits CLI entry: resolves persona from `argv[0]` and delegates to the CLI host.

const builtin = @import("builtin");
const std = @import("std");
const host = @import("cli/host.zig");
const persona_resolve = @import("cli/persona_resolve.zig");

/// Program entry: resolves persona, runs subcommand dispatch.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv0 = blk: {
        var it = try init.minimal.args.iterateAllocator(allocator);
        defer it.deinit();
        break :blk it.next() orelse "fits";
    };

    var resolved = try persona_resolve.resolve(allocator, io, init.environ_map, argv0, ".");
    defer resolved.deinit(allocator);

    const first_cmd = blk: {
        var peek = try init.minimal.args.iterateAllocator(allocator);
        defer peek.deinit();
        _ = peek.next();
        break :blk peek.next() orelse "";
    };

    if (!builtin.is_test and host.shouldBackgroundUpdate(&resolved, first_cmd)) {
        const update_mod = @import("app/update.zig");
        if (update_mod.shouldSpawnBackgroundCheck(allocator, io, init.environ_map) catch false) {
            update_mod.spawnBackgroundCheck(allocator, io, init.environ_map) catch {};
        }
    }

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    host.runCli(&resolved, allocator, io, init.environ_map, &args) catch |err| switch (err) {
        // Usage/argv mistakes already printed; exit without Zig's error stack trace.
        error.InvalidArgv, error.CommandNotAllowed => std.process.exit(1),
        else => return err,
    };
}

test {
    _ = @import("adapters/fs/fits_registry.zig");
    _ = @import("adapters/fs/registry_validate.zig");
    _ = @import("adapters/fs/fits_config.zig");
    _ = @import("adapters/cache/fits_cache.zig");
    _ = @import("adapters/github/release.zig");
    _ = @import("app/update.zig");
    _ = @import("app/new_link.zig");
    _ = @import("app/new_node.zig");
    _ = @import("app/register.zig");
    _ = @import("app/init_repo.zig");
    _ = @import("test/fits_registry_functional.zig");
    _ = @import("test/new_link_functional.zig");
    _ = @import("test/new_node_functional.zig");
    _ = @import("test/register_functional.zig");
    _ = @import("test/register_rm_functional.zig");
    _ = @import("test/links_functional.zig");
    _ = @import("test/remove_object_functional.zig");
    _ = @import("test/update_functional.zig");
    _ = @import("test/init_functional.zig");
    _ = @import("test/persona_resolve_functional.zig");
    _ = @import("test/persona_host_functional.zig");
    _ = @import("adapters/git/removal.zig");
    _ = @import("domain/instance_id.zig");
    _ = @import("domain/graph_subgraph.zig");
    _ = @import("domain/hook_protocol.zig");
    _ = @import("adapters/hooks/git_dirty.zig");
    _ = @import("adapters/hooks/hook_request.zig");
    _ = @import("app/hooks_validate.zig");
    _ = @import("app/rebuild_cache.zig");
    _ = @import("cli/persona_manifest.zig");
    _ = @import("adapters/fs/registry_snapshot.zig");
}
