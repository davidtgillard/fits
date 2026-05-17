//! Clear hook fingerprint cache entries and repopulate via a full-graph hook run.

const builtin = @import("builtin");
const std = @import("std");
const persona = @import("../cli/persona.zig");
const extension_run = @import("../cli/extension_run.zig");
const loader_mod = @import("../adapters/fs/loader.zig");
const ignore_mod = @import("../adapters/git/ignore.zig");
const cache_mod = @import("../adapters/cache/latticedb_cache.zig");
const fits_registry_mod = @import("../adapters/fs/fits_registry.zig");
const links_index_mod = @import("../adapters/fs/links_index.zig");
const links_validate_mod = @import("../adapters/fs/links_validate.zig");
const graph_mod = @import("../domain/graph.zig");
const graph_builder_mod = @import("../domain/graph_builder.zig");
const report_mod = @import("../output/report.zig");
const new_node_mod = @import("new_node.zig");
const hooks_validate_mod = @import("hooks_validate.zig");
const hooks_config_mod = @import("../adapters/fs/hooks_config.zig");
const registry_snapshot = @import("../adapters/fs/registry_snapshot.zig");

const ResolvedPersona = persona.ResolvedPersona;
const Io = std.Io;

/// Clears hook fingerprints, then runs hooks on the full graph and persists new fingerprints.
///
/// Parameters:
/// - `resolved`: Active persona (registry guard and hook argv resolution).
/// - `allocator`: Allocator for loads and findings.
/// - `io`: Filesystem I/O handle.
/// - `environ`: Process environment (`HOME` for global cache fallback).
///
/// Returns: void when the cache was cleared and hook output was rendered.
/// On failure: registry/links load errors, cache I/O, or hook subprocess errors propagated as findings then normal exit.
pub fn run(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !void {
    var reg = try fits_registry_mod.loadRegistry(allocator, io, ".");
    defer reg.deinit();
    try ensureFixedRegistry(resolved, allocator, io, &reg);

    var link_report = links_validate_mod.ValidationReport{ .allocator = allocator };
    defer link_report.deinit();

    var loaded = links_index_mod.loadLinks(allocator, io, ".", &reg, &link_report) catch |err| switch (err) {
        error.LinksInvalid => {
            const lp = try links_index_mod.formatLinksRelPath(allocator, ".");
            defer allocator.free(lp);
            link_report.print(lp);
            return err;
        },
        else => |e| return e,
    };
    defer loaded.deinit();

    var link_edges = try allocator.alloc(graph_mod.LinkEdgeInput, loaded.rows().len);
    defer allocator.free(link_edges);
    for (loaded.rows(), 0..) |r, i| {
        link_edges[i] = .{
            .link_type = r.link_type,
            .out_id = r.out,
            .in_id = r.in,
        };
    }

    const ignore = ignore_mod.IgnoreMatcher.init(".");
    const loader = loader_mod.Loader.init(ignore);
    const id_prefixes = try reg.idPrefixSlice(allocator);
    defer allocator.free(id_prefixes);

    const bundles = try loader.loadNodeBundles(allocator, io, ".", new_node_mod.default_objects_dir, &reg, id_prefixes);
    defer allocator.free(bundles);

    var hook_snapshot_builder = graph_builder_mod.DeterministicGraphBuilder{};
    const hook_snapshot = try hook_snapshot_builder.asInterface().build(allocator, bundles, link_edges);
    defer hook_snapshot.deinit(allocator);

    const store_dir = try cache_mod.LatticeDbCache.resolveStoreDir(allocator, io, environ, ".");
    defer allocator.free(store_dir);
    var cache = try cache_mod.LatticeDbCache.open(allocator, io, store_dir);
    defer cache.deinit();

    try cache.clearHookFingerprints();

    var hook_cfg = hooks_config_mod.HooksConfig{};
    defer hook_cfg.deinit(allocator);

    if (resolved.manifest) |m| {
        if (m.primaryHook()) |hook_def| {
            hook_cfg.enabled = m.validate_hooks_default;
            hook_cfg.nodes_argv = try extension_run.resolveHookArgv(allocator, io, resolved.package_root, hook_def.nodes_argv);
            hook_cfg.links_argv = try extension_run.resolveHookArgv(allocator, io, resolved.package_root, hook_def.links_argv);
            hook_cfg.timeout_ns = hook_def.timeout_secs * std.time.ns_per_s;
        }
    } else {
        hook_cfg = try hooks_config_mod.load(allocator, io, ".");
    }

    if (!hook_cfg.enabled) {
        std.debug.print("cleared hook fingerprint cache (hooks disabled; not repopulated)\n", .{});
        return;
    }

    const run_id = try makeRunId(allocator);
    defer allocator.free(run_id);

    const git_head_opt = tryGitHead(allocator, io, ".");
    defer if (git_head_opt) |h| allocator.free(h);

    const hook_findings = try hooks_validate_mod.runHooks(
        allocator,
        io,
        ".",
        &reg,
        &loaded,
        bundles,
        &hook_snapshot,
        &cache,
        &hook_cfg,
        true,
        false,
        run_id,
        git_head_opt,
    );
    defer {
        for (hook_findings) |f| allocator.free(f.message);
        allocator.free(hook_findings);
    }

    const final_report = report_mod.Report{
        .findings = hook_findings,
        .summary = report_mod.summarize(hook_findings),
    };

    var renderer = report_mod.TextRenderer{};
    try renderer.asInterface().render(final_report);
}

fn ensureFixedRegistry(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: Io, reg: *const fits_registry_mod.Registry) !void {
    if (!resolved.fixedRegistry()) return;
    const m = resolved.manifest.?;
    try registry_snapshot.verifyRegistryForPersona(allocator, io, resolved.package_root, m.snapshot_rel, reg);
}

fn tryGitHead(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_root, "rev-parse", "HEAD" },
        .cwd = .inherit,
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const copy = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return copy;
}

fn makeRunId(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.REALTIME, &ts) == 0) {
            return try std.fmt.allocPrint(allocator, "rebuild-cache-{d}-{d}", .{ ts.sec, ts.nsec });
        }
    }
    return try allocator.dupe(u8, "rebuild-cache");
}
