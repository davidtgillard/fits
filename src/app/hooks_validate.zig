//! Run optional JSON stdin/stdout hooks after the built-in validate graph pass.

const std = @import("std");
const graph = @import("../domain/graph.zig");
const hook_protocol = @import("../domain/hook_protocol.zig");
const validation = @import("../domain/validation.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const fits_config = @import("../adapters/fs/fits_config.zig");
const hooks_config = @import("../adapters/fs/hooks_config.zig");
const hook_request = @import("../adapters/hooks/hook_request.zig");
const subprocess_hook = @import("../adapters/hooks/subprocess_runner.zig");
const git_dirty = @import("../adapters/hooks/git_dirty.zig");
const lattice = @import("../adapters/cache/latticedb_cache.zig");

const Io = std.Io;

/// Runs graph-node and/or link hooks and returns owned findings (empty when disabled).
pub fn runHooks(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    reg: *fits_registry.Registry,
    loaded: *links_index.LoadedLinks,
    bundles: []const graph.NodeBundle,
    full_snapshot: *const graph.GraphSnapshot,
    cache: *lattice.LatticeDbCache,
    cfg: *const hooks_config.HooksConfig,
    cli_hooks: bool,
    hooks_full: bool,
    hooks_incremental: bool,
    run_id: []const u8,
    git_head: ?[]const u8,
) ![]validation.Finding {
    var out: std.ArrayListUnmanaged(validation.Finding) = .empty;
    defer {
        for (out.items) |f| allocator.free(f.message);
        out.deinit(allocator);
    }

    if (!cli_hooks or !cfg.enabled) {
        return try out.toOwnedSlice(allocator);
    }

    const use_git_narrowing = hooks_incremental and !hooks_full;
    var git_state: git_dirty.GitDirtyState = .{};
    if (use_git_narrowing) {
        git_state = try git_dirty.load(allocator, io, repo_root);
    }
    defer git_state.deinit(allocator);
    const git_ptr: ?*const git_dirty.GitDirtyState = if (use_git_narrowing) &git_state else null;

    if (cfg.nodes_argv.len != 0) {
        const work_objs = try filterBundles(allocator, cache, "node", cfg.nodes_argv, hooks_full, hooks_incremental, git_ptr, bundles);
        defer {
            for (work_objs) |*b| freeBundle(allocator, b);
            allocator.free(work_objs);
        }
        if (work_objs.len != 0) {
            const body = try hook_request.nodeRequestJson(allocator, reg, full_snapshot, work_objs, run_id, git_head, "validate");
            defer allocator.free(body);
            if (body.len > cfg.max_request_bytes) {
                const msg = try std.fmt.allocPrint(allocator, "nodes hook request too large ({d} > {d})", .{ body.len, cfg.max_request_bytes });
                defer allocator.free(msg);
                const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "nodes", msg);
                defer {
                    for (batch) |f| allocator.free(f.message);
                    allocator.free(batch);
                }
                try out.appendSlice(allocator, batch);
            } else {
                const to = timeoutFromNs(cfg.timeout_ns);
                if (subprocess_hook.runHook(allocator, io, cfg.nodes_argv, body, cfg.max_request_bytes, 64 * 1024, to)) |rh| {
                    defer {
                        allocator.free(rh.stdout);
                        allocator.free(rh.stderr);
                    }
                    switch (rh.term) {
                        .exited => |code| {
                            if (code != 0) {
                                const msg = try std.fmt.allocPrint(allocator, "exit {d}: {s}", .{ code, rh.stderr });
                                defer allocator.free(msg);
                                const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "nodes", msg);
                                defer {
                                    for (batch) |f| allocator.free(f.message);
                                    allocator.free(batch);
                                }
                                try out.appendSlice(allocator, batch);
                            } else {
                                try hook_protocol.appendFindingsFromHookResponseJson(allocator, rh.stdout, "nodes", &out);
                                try persistNodeFingerprints(allocator, cache, cfg.nodes_argv, work_objs);
                            }
                        },
                        else => {
                            const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "nodes", "abnormal termination");
                            defer {
                                for (batch) |f| allocator.free(f.message);
                                allocator.free(batch);
                            }
                            try out.appendSlice(allocator, batch);
                        },
                    }
                } else |err| {
                    const msg = try std.fmt.allocPrint(allocator, "nodes hook: {any}", .{err});
                    defer allocator.free(msg);
                    const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "nodes", msg);
                    defer {
                        for (batch) |f| allocator.free(f.message);
                        allocator.free(batch);
                    }
                    try out.appendSlice(allocator, batch);
                }
            }
        }
    }

    if (cfg.links_argv.len != 0) {
        var prefs = try fits_config.loadParsedConfigForRepo(allocator, io, repo_root);
        defer prefs.deinit();

        const rows = loaded.rows();
        const work_rows = try filterLinks(allocator, cache, cfg.links_argv, hooks_full, hooks_incremental, git_ptr, rows);
        defer allocator.free(work_rows);

        if (work_rows.len != 0) {
            const body = try hook_request.linkRequestJson(allocator, io, repo_root, reg, full_snapshot, &prefs, work_rows, run_id, git_head, "validate");
            defer allocator.free(body);
            if (body.len > cfg.max_request_bytes) {
                const msg = try std.fmt.allocPrint(allocator, "links hook request too large ({d} > {d})", .{ body.len, cfg.max_request_bytes });
                defer allocator.free(msg);
                const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "links", msg);
                defer {
                    for (batch) |f| allocator.free(f.message);
                    allocator.free(batch);
                }
                try out.appendSlice(allocator, batch);
            } else {
                const to = timeoutFromNs(cfg.timeout_ns);
                if (subprocess_hook.runHook(allocator, io, cfg.links_argv, body, cfg.max_request_bytes, 64 * 1024, to)) |rh| {
                    defer {
                        allocator.free(rh.stdout);
                        allocator.free(rh.stderr);
                    }
                    switch (rh.term) {
                        .exited => |code| {
                            if (code != 0) {
                                const msg = try std.fmt.allocPrint(allocator, "exit {d}: {s}", .{ code, rh.stderr });
                                defer allocator.free(msg);
                                const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "links", msg);
                                defer {
                                    for (batch) |f| allocator.free(f.message);
                                    allocator.free(batch);
                                }
                                try out.appendSlice(allocator, batch);
                            } else {
                                try hook_protocol.appendFindingsFromHookResponseJson(allocator, rh.stdout, "links", &out);
                                try persistLinkFingerprints(allocator, cache, cfg.links_argv, work_rows);
                            }
                        },
                        else => {
                            const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "links", "abnormal termination");
                            defer {
                                for (batch) |f| allocator.free(f.message);
                                allocator.free(batch);
                            }
                            try out.appendSlice(allocator, batch);
                        },
                    }
                } else |err| {
                    const msg = try std.fmt.allocPrint(allocator, "links hook: {any}", .{err});
                    defer allocator.free(msg);
                    const batch = try hook_protocol.findingsFromHookIoFailure(allocator, "links", msg);
                    defer {
                        for (batch) |f| allocator.free(f.message);
                        allocator.free(batch);
                    }
                    try out.appendSlice(allocator, batch);
                }
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn timeoutFromNs(ns: u64) Io.Timeout {
    if (ns == 0) return .none;
    return .{ .duration = .{
        .raw = Io.Duration.fromNanoseconds(@intCast(ns)),
        .clock = .awake,
    } };
}

fn freeBundle(allocator: std.mem.Allocator, b: *graph.NodeBundle) void {
    allocator.free(b.id);
    for (b.files) |f| allocator.free(f.contents);
    for (b.files) |f| allocator.free(f.relative_path);
    allocator.free(b.files);
    b.* = undefined;
}

fn argvHash(argv: []const []const u8) u64 {
    var w = std.hash.Wyhash.init(0);
    for (argv) |a| {
        w.update(a);
        w.update("\x00");
    }
    return w.final();
}

fn fingerprintBundle(b: graph.NodeBundle) u64 {
    var w = std.hash.Wyhash.init(0);
    w.update(b.id);
    w.update("\x00");
    if (b.files.len == 0) return w.final();
    const order = std.heap.page_allocator.alloc(usize, b.files.len) catch return 0;
    defer std.heap.page_allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sortUnstable(usize, order, b.files, struct {
        fn less(fs: []const graph.NodeFile, a: usize, c: usize) bool {
            return std.mem.order(u8, fs[a].relative_path, fs[c].relative_path) == .lt;
        }
    }.less);
    for (order) |i| {
        const f = b.files[i];
        w.update(f.relative_path);
        w.update("\x00");
        w.update(f.contents);
    }
    return w.final();
}

fn cloneBundle(allocator: std.mem.Allocator, b: graph.NodeBundle) !graph.NodeBundle {
    const id = try allocator.dupe(u8, b.id);
    errdefer allocator.free(id);
    const files = try allocator.alloc(graph.NodeFile, b.files.len);
    errdefer {
        for (files) |g| allocator.free(g.contents);
        for (files) |g| allocator.free(g.relative_path);
        allocator.free(files);
    }
    for (b.files, 0..) |f, i| {
        files[i] = .{
            .relative_path = try allocator.dupe(u8, f.relative_path),
            .contents = try allocator.dupe(u8, f.contents),
        };
    }
    return .{ .id = id, .files = files };
}

fn filterBundles(
    allocator: std.mem.Allocator,
    cache: *lattice.LatticeDbCache,
    tag: []const u8,
    argv: []const []const u8,
    hooks_full: bool,
    hooks_incremental: bool,
    git: ?*const git_dirty.GitDirtyState,
    bundles: []const graph.NodeBundle,
) ![]graph.NodeBundle {
    if (hooks_full or !hooks_incremental) {
        var out = try allocator.alloc(graph.NodeBundle, bundles.len);
        errdefer {
            for (out) |*b| freeBundle(allocator, b);
            allocator.free(out);
        }
        for (bundles, 0..) |b, i| {
            out[i] = try cloneBundle(allocator, b);
        }
        return out;
    }

    const ah = argvHash(argv);
    var list: std.ArrayListUnmanaged(graph.NodeBundle) = .empty;
    errdefer {
        for (list.items) |*b| freeBundle(allocator, b);
        list.deinit(allocator);
    }

    for (bundles) |b| {
        if (git) |g| {
            if (g.have_git and !g.node_ids.contains(b.id)) continue;
        }
        const fp = fingerprintBundle(b);
        const key = try cacheKey(allocator, tag, ah, b.id);
        defer allocator.free(key);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, fp, .little);
        const old_opt = try cache.get(key);
        defer if (old_opt) |old| cache.allocator.free(old);
        if (old_opt) |old| {
            if (old.len == 8 and std.mem.eql(u8, old, &buf)) continue;
        }
        try list.append(allocator, try cloneBundle(allocator, b));
    }
    return try list.toOwnedSlice(allocator);
}

fn fingerprintLink(r: links_index.LinkRowJson) u64 {
    var w = std.hash.Wyhash.init(0);
    w.update(r.id);
    w.update(r.link_type);
    w.update(r.out);
    w.update(r.in);
    return w.final();
}

fn filterLinks(
    allocator: std.mem.Allocator,
    cache: *lattice.LatticeDbCache,
    argv: []const []const u8,
    hooks_full: bool,
    hooks_incremental: bool,
    git: ?*const git_dirty.GitDirtyState,
    rows: []const links_index.LinkRowJson,
) ![]links_index.LinkRowJson {
    if (hooks_full or !hooks_incremental) {
        return try allocator.dupe(links_index.LinkRowJson, rows);
    }
    const ah = argvHash(argv);
    var list: std.ArrayListUnmanaged(links_index.LinkRowJson) = .empty;
    errdefer list.deinit(allocator);

    for (rows) |r| {
        if (git) |g| {
            if (g.have_git) {
                if (!g.links_index_dirty) {
                    if (g.link_folder_ids.count() == 0) continue;
                    if (!g.link_folder_ids.contains(r.id)) continue;
                }
            }
        }
        const fp = fingerprintLink(r);
        const key = try cacheKey(allocator, "link", ah, r.id);
        defer allocator.free(key);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, fp, .little);
        const old_opt = try cache.get(key);
        defer if (old_opt) |old| cache.allocator.free(old);
        if (old_opt) |old| {
            if (old.len == 8 and std.mem.eql(u8, old, &buf)) continue;
        }
        try list.append(allocator, r);
    }
    return try list.toOwnedSlice(allocator);
}

fn cacheKey(allocator: std.mem.Allocator, kind: []const u8, argv_hash: u64, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "hooks:{s}:{d}:{s}", .{ kind, argv_hash, id });
}

fn persistNodeFingerprints(
    allocator: std.mem.Allocator,
    cache: *lattice.LatticeDbCache,
    argv: []const []const u8,
    bundles: []const graph.NodeBundle,
) !void {
    const ah = argvHash(argv);
    for (bundles) |b| {
        const key = try cacheKey(allocator, "node", ah, b.id);
        defer allocator.free(key);
        const fp = fingerprintBundle(b);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, fp, .little);
        try cache.put(key, &buf);
    }
}

fn persistLinkFingerprints(
    allocator: std.mem.Allocator,
    cache: *lattice.LatticeDbCache,
    argv: []const []const u8,
    rows: []const links_index.LinkRowJson,
) !void {
    const ah = argvHash(argv);
    for (rows) |r| {
        const key = try cacheKey(allocator, "link", ah, r.id);
        defer allocator.free(key);
        const fp = fingerprintLink(r);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, fp, .little);
        try cache.put(key, &buf);
    }
}
