//! Serialize hook stdin JSON (protocol 2) using an arena for nested [`std.json.Value`] trees.

const std = @import("std");
const graph = @import("../../domain/graph.zig");
const graph_subgraph = @import("../../domain/graph_subgraph.zig");
const hook_protocol = @import("../../domain/hook_protocol.zig");
const fits_registry = @import("../fs/fits_registry.zig");
const links_index = @import("../fs/links_index.zig");
const fits_config = @import("../fs/fits_config.zig");
const path_layout = @import("../fs/path_layout.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const max_file_bytes: usize = 16 * 1024 * 1024;

/// Allocates the UTF-8 JSON body with `allocator`. Arena scratch state is freed before return.
pub fn nodeRequestJson(
    allocator: std.mem.Allocator,
    reg: *fits_registry.Registry,
    full: *const graph.GraphSnapshot,
    work: []const graph.NodeBundle,
    run_id: []const u8,
    git_head: ?[]const u8,
    trigger: []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var seeds = try a.alloc([]const u8, work.len);
    for (work, 0..) |b, i| seeds[i] = b.id;

    var sub = try graph_subgraph.extractIncidentSubgraph(a, full, .{
        .node_ids = seeds,
        .extra_ids = &.{},
    }, .{});
    defer sub.deinit(a);

    const reg_text = try reg.toJsonText();
    defer allocator.free(reg_text);
    const reg_val = try std.json.parseFromSliceLeaky(JsonValue, a, reg_text, .{});

    var root: ObjectMap = .empty;
    try root.put(a, "protocol_version", .{ .integer = @intCast(hook_protocol.protocol_version) });
    try root.put(a, "extension_graph_api", .{ .string = hook_protocol.extension_graph_api_placeholder });

    var run_o: ObjectMap = .empty;
    try run_o.put(a, "run_id", .{ .string = try a.dupe(u8, run_id) });
    try run_o.put(a, "trigger", .{ .string = try a.dupe(u8, trigger) });
    try run_o.put(a, "git_head", if (git_head) |h| .{ .string = try a.dupe(u8, h) } else .null);
    try root.put(a, "run", .{ .object = run_o });
    try root.put(a, "registry", reg_val);

    var graph_o: ObjectMap = .empty;
    var nodes_a = std.json.Array.init(a);
    for (sub.nodes) |n| {
        var no: ObjectMap = .empty;
        try no.put(a, "id", .{ .string = n.id });
        try nodes_a.append(.{ .object = no });
    }
    var edges_a = std.json.Array.init(a);
    for (sub.edges) |e| {
        var eo: ObjectMap = .empty;
        const kind: []const u8 = switch (e.kind) {
            .references => "references",
            .registered_link => "registered_link",
        };
        try eo.put(a, "from_id", .{ .string = e.from_id });
        try eo.put(a, "to_id", .{ .string = e.to_id });
        try eo.put(a, "kind", .{ .string = kind });
        try eo.put(a, "link_type", .{ .string = e.link_type });
        try edges_a.append(.{ .object = eo });
    }
    try graph_o.put(a, "nodes", .{ .array = nodes_a });
    try graph_o.put(a, "edges", .{ .array = edges_a });
    try root.put(a, "graph", .{ .object = graph_o });

    var work_o: ObjectMap = .empty;
    var wo = std.json.Array.init(a);
    for (work) |bundle| {
        try wo.append(try nodeWorkItem(a, bundle));
    }
    try work_o.put(a, "nodes", .{ .array = wo });
    try root.put(a, "work", .{ .object = work_o });

    const root_val = JsonValue{ .object = root };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root_val, .{})});
}

/// Link-hook request: `work.links` includes optional `folder_files` when configured.
pub fn linkRequestJson(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    reg: *fits_registry.Registry,
    full: *const graph.GraphSnapshot,
    prefs: *fits_config.ParsedConfig,
    work: []const links_index.LinkRowJson,
    run_id: []const u8,
    git_head: ?[]const u8,
    trigger: []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var extra = try a.alloc([]const u8, work.len * 2);
    defer a.free(extra);
    var xi: usize = 0;
    for (work) |row| {
        extra[xi] = row.out;
        xi += 1;
        extra[xi] = row.in;
        xi += 1;
    }

    var sub = try graph_subgraph.extractIncidentSubgraph(a, full, .{
        .node_ids = &.{},
        .extra_ids = extra[0..xi],
    }, .{});
    defer sub.deinit(a);

    const reg_text = try reg.toJsonText();
    defer allocator.free(reg_text);
    const reg_val = try std.json.parseFromSliceLeaky(JsonValue, a, reg_text, .{});

    var root: ObjectMap = .empty;
    try root.put(a, "protocol_version", .{ .integer = @intCast(hook_protocol.protocol_version) });
    try root.put(a, "extension_graph_api", .{ .string = hook_protocol.extension_graph_api_placeholder });

    var run_o: ObjectMap = .empty;
    try run_o.put(a, "run_id", .{ .string = try a.dupe(u8, run_id) });
    try run_o.put(a, "trigger", .{ .string = try a.dupe(u8, trigger) });
    try run_o.put(a, "git_head", if (git_head) |h| .{ .string = try a.dupe(u8, h) } else .null);
    try root.put(a, "run", .{ .object = run_o });
    try root.put(a, "registry", reg_val);

    var graph_o: ObjectMap = .empty;
    var nodes_a = std.json.Array.init(a);
    for (sub.nodes) |n| {
        var no: ObjectMap = .empty;
        try no.put(a, "id", .{ .string = n.id });
        try nodes_a.append(.{ .object = no });
    }
    var edges_a = std.json.Array.init(a);
    for (sub.edges) |e| {
        var eo: ObjectMap = .empty;
        const kind: []const u8 = switch (e.kind) {
            .references => "references",
            .registered_link => "registered_link",
        };
        try eo.put(a, "from_id", .{ .string = e.from_id });
        try eo.put(a, "to_id", .{ .string = e.to_id });
        try eo.put(a, "kind", .{ .string = kind });
        try eo.put(a, "link_type", .{ .string = e.link_type });
        try edges_a.append(.{ .object = eo });
    }
    try graph_o.put(a, "nodes", .{ .array = nodes_a });
    try graph_o.put(a, "edges", .{ .array = edges_a });
    try root.put(a, "graph", .{ .object = graph_o });

    var work_o: ObjectMap = .empty;
    var wl = std.json.Array.init(a);
    for (work) |row| {
        try wl.append(try linkWorkItem(allocator, a, io, repo_root, prefs, row));
    }
    try work_o.put(a, "links", .{ .array = wl });
    try root.put(a, "work", .{ .object = work_o });

    const root_val = JsonValue{ .object = root };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root_val, .{})});
}

fn nodeWorkItem(a: std.mem.Allocator, bundle: graph.NodeBundle) !JsonValue {
    var o: ObjectMap = .empty;
    try o.put(a, "id", .{ .string = try a.dupe(u8, bundle.id) });
    var fa = std.json.Array.init(a);
    for (bundle.files) |f| {
        const enc: []const u8 = if (std.unicode.utf8ValidateSlice(f.contents)) "utf-8" else "base64";
        var fo: ObjectMap = .empty;
        try fo.put(a, "relative_path", .{ .string = try a.dupe(u8, f.relative_path) });
        try fo.put(a, "encoding", .{ .string = enc });
        if (std.mem.eql(u8, enc, "utf-8")) {
            try fo.put(a, "content", .{ .string = try a.dupe(u8, f.contents) });
        } else {
            const e = std.base64.standard.Encoder;
            const out_len = e.calcSize(f.contents.len);
            const b64 = try a.alloc(u8, out_len);
            _ = e.encode(b64, f.contents);
            try fo.put(a, "content", .{ .string = b64 });
        }
        try fa.append(.{ .object = fo });
    }
    try o.put(a, "files", .{ .array = fa });
    return .{ .object = o };
}

fn linkWorkItem(
    parent_alloc: std.mem.Allocator,
    a: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    prefs: *fits_config.ParsedConfig,
    row: links_index.LinkRowJson,
) !JsonValue {
    var o: ObjectMap = .empty;
    try o.put(a, "id", .{ .string = row.id });
    try o.put(a, "link_type", .{ .string = row.link_type });
    try o.put(a, "out", .{ .string = row.out });
    try o.put(a, "in", .{ .string = row.in });
    if (row.labels) |ls| {
        var la = std.json.Array.init(a);
        for (ls) |s| try la.append(.{ .string = s });
        try o.put(a, "labels", .{ .array = la });
    }
    var folder_a = std.json.Array.init(a);
    if (prefs.linkCreateFolder(row.link_type) orelse false) {
        var scanned = try scanLinkFolder(parent_alloc, io, repo_root, row.link_type, row.id);
        defer {
            for (scanned.items) |ent| {
                parent_alloc.free(ent.rel);
                parent_alloc.free(ent.payload);
            }
            scanned.deinit(parent_alloc);
        }
        for (scanned.items) |ent| {
            var fo: ObjectMap = .empty;
            try fo.put(a, "relative_path", .{ .string = try a.dupe(u8, ent.rel) });
            const encs: []const u8 = if (ent.utf8) "utf-8" else "base64";
            try fo.put(a, "encoding", .{ .string = encs });
            try fo.put(a, "content", .{ .string = try a.dupe(u8, ent.payload) });
            try folder_a.append(.{ .object = fo });
        }
    }
    try o.put(a, "folder_files", .{ .array = folder_a });
    return .{ .object = o };
}

const Scanned = struct {
    rel: []const u8,
    utf8: bool,
    payload: []const u8,
};

fn scanLinkFolder(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    link_type: []const u8,
    link_id: []const u8,
) !std.ArrayListUnmanaged(Scanned) {
    const rel_dir = try path_layout.linkInstanceDir(allocator, link_type, link_id);
    defer allocator.free(rel_dir);
    const abs_dir = try std.fs.path.join(allocator, &.{ repo_root, rel_dir });
    defer allocator.free(abs_dir);

    var out: std.ArrayListUnmanaged(Scanned) = .empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.rel);
            allocator.free(e.payload);
        }
        out.deinit(allocator);
    }

    walkRel(allocator, io, abs_dir, "", &out) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    return out;
}

fn walkRel(
    allocator: std.mem.Allocator,
    io: Io,
    abs: []const u8,
    rel: []const u8,
    out: *std.ArrayListUnmanaged(Scanned),
) !void {
    var dir = try openDirIo(io, abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind == .sym_link) continue;
        const jabs = try std.fs.path.join(allocator, &.{ abs, ent.name });
        defer allocator.free(jabs);
        const jrel: []const u8 = if (rel.len == 0)
            try allocator.dupe(u8, ent.name)
        else
            try std.fs.path.join(allocator, &.{ rel, ent.name });
        defer allocator.free(jrel);

        switch (ent.kind) {
            .directory => try walkRel(allocator, io, jabs, jrel, out),
            .file => {
                var f = try openFileIo(io, jabs);
                defer f.close(io);
                const st = try f.stat(io);
                const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
                if (n > max_file_bytes) return error.FileTooBig;
                const buf = try allocator.alloc(u8, n);
                errdefer allocator.free(buf);
                const got = try f.readPositionalAll(io, buf, 0);
                if (got != n) return error.UnexpectedEndOfFile;
                const utf8 = std.unicode.utf8ValidateSlice(buf);
                const content_out: []const u8 = if (utf8) blk: {
                    break :blk buf;
                } else blk: {
                    const e = std.base64.standard.Encoder;
                    const olen = e.calcSize(buf.len);
                    const b64 = try allocator.alloc(u8, olen);
                    _ = e.encode(b64, buf);
                    allocator.free(buf);
                    break :blk b64;
                };
                const rel_owned = try allocator.dupe(u8, jrel);
                errdefer allocator.free(rel_owned);
                try out.append(allocator, .{
                    .rel = rel_owned,
                    .utf8 = utf8,
                    .payload = content_out,
                });
            },
            else => {},
        }
    }
}

fn openDirIo(io: Io, path: []const u8, opt: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    if (std.fs.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, opt);
    return Io.Dir.cwd().openDir(io, path, opt);
}

fn openFileIo(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) return Io.Dir.openFileAbsolute(io, path, .{});
    return Io.Dir.cwd().openFile(io, path, .{});
}
