//! Loads, validates, and writes [`links/links.jsonc`].

const std = @import("std");
const fits_registry = @import("fits_registry.zig");
const jsonc_strip = @import("jsonc_strip.zig");
const links_validate = @import("links_validate.zig");
const instance_id = @import("../../domain/instance_id.zig");
const path_layout = @import("path_layout.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Directory under the repo root holding `links.jsonc` and per-link-type folders.
pub const links_dir_name: []const u8 = path_layout.links_root;

/// Deprecated alias; use [`links_dir_name`].
pub const relations_dir_name: []const u8 = links_dir_name;

/// Human-editable JSONC index of link instances.
pub const links_file_name: []const u8 = "links.jsonc";

/// One link row as stored in `links.jsonc`.
pub const LinkRowJson = struct {
    id: []const u8,
    link_type: []const u8,
    out: []const u8,
    in: []const u8,
    labels: ?[][]const u8 = null,
};

/// Top-level document shape for `links.jsonc`.
pub const LinksEnvelope = struct {
    description: []const u8,
    version: u32,
    kind: []const u8,
    links: []const LinkRowJson,
};

pub const LoadedLinks = struct {
    allocator: std.mem.Allocator,
    stripped_owned: []const u8,
    parsed: std.json.Parsed(LinksEnvelope),

    pub fn deinit(self: *LoadedLinks) void {
        self.parsed.deinit();
        self.allocator.free(self.stripped_owned);
    }

    pub fn rows(self: *const LoadedLinks) []const LinkRowJson {
        return self.parsed.value.links;
    }
};

/// Minimal document when the file does not exist yet.
const empty_links_json: []const u8 =
    \\{"description":"Directed links between issued object ids. Edit by hand or via fits CLI; validate with fits validate.","version":1,"kind":"fits-links-v1","links":[]}
;

fn openPath(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

fn readFileAlloc(io: Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    var file = openPath(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer file.close(io);
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}

/// Joins `repo_root/links/links.jsonc` (caller frees).
pub fn joinLinksAbsPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return path_layout.linksIndexRel(allocator, repo_root);
}

/// Display path when reporting issues (e.g. `links/links.jsonc`).
pub fn formatLinksRelPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return path_layout.linksIndexRel(allocator, repo_root);
}

/// Loads and validates links; appends structural and semantic issues to `report`.
///
/// Returns: parsed links on success when `report` is empty after the call.
pub fn loadLinks(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    registry: *const fits_registry.Registry,
    report: *links_validate.ValidationReport,
) !LoadedLinks {
    const path = try joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(path);

    const raw_owned = readFileAlloc(io, allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            const dup = try allocator.dupe(u8, empty_links_json);
            const parsed = try std.json.parseFromSlice(LinksEnvelope, allocator, dup, .{});
            return LoadedLinks{
                .allocator = allocator,
                .stripped_owned = dup,
                .parsed = parsed,
            };
        },
        else => |e| return e,
    };
    defer allocator.free(raw_owned);

    const stripped = try jsonc_strip.stripJsoncComments(allocator, raw_owned);
    errdefer allocator.free(stripped);

    var struct_rep = try links_validate.validateLinksDocument(allocator, stripped);
    defer struct_rep.deinit();

    if (!struct_rep.isEmpty()) {
        try links_validate.appendReport(report, &struct_rep);
        return error.LinksInvalid;
    }

    const parsed = std.json.parseFromSlice(LinksEnvelope, allocator, stripped, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try links_validate.pushIssue(report, "$", msg);
        return error.LinksInvalid;
    };

    var views = try allocator.alloc(links_validate.LinkRowView, parsed.value.links.len);
    defer allocator.free(views);
    for (parsed.value.links, 0..) |r, i| {
        views[i] = .{
            .id = r.id,
            .link_type = r.link_type,
            .out = r.out,
            .in = r.in,
        };
    }
    links_validate.validateLinksAgainstRegistryRows(report, registry, views);

    if (!report.isEmpty()) {
        parsed.deinit();
        allocator.free(stripped);
        return error.LinksInvalid;
    }

    return LoadedLinks{
        .allocator = allocator,
        .stripped_owned = stripped,
        .parsed = parsed,
    };
}

/// Loads `links.jsonc` with structural validation only (no registry semantics).
pub fn loadLinksStructuralOnly(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    report: *links_validate.ValidationReport,
) !LoadedLinks {
    const path = try joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(path);

    const raw_owned = readFileAlloc(io, allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            const dup = try allocator.dupe(u8, empty_links_json);
            const parsed = try std.json.parseFromSlice(LinksEnvelope, allocator, dup, .{});
            return LoadedLinks{
                .allocator = allocator,
                .stripped_owned = dup,
                .parsed = parsed,
            };
        },
        else => |e| return e,
    };
    defer allocator.free(raw_owned);

    const stripped = try jsonc_strip.stripJsoncComments(allocator, raw_owned);
    errdefer allocator.free(stripped);

    var struct_rep = try links_validate.validateLinksDocument(allocator, stripped);
    defer struct_rep.deinit();

    if (!struct_rep.isEmpty()) {
        try links_validate.appendReport(report, &struct_rep);
        return error.LinksInvalid;
    }

    const parsed = std.json.parseFromSlice(LinksEnvelope, allocator, stripped, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try links_validate.pushIssue(report, "$", msg);
        return error.LinksInvalid;
    };

    return LoadedLinks{
        .allocator = allocator,
        .stripped_owned = stripped,
        .parsed = parsed,
    };
}

/// Rewrites `link_type` and link `id` prefixes after `fits register rename-type` on a link type.
pub fn rewriteLinkTypeRows(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    old_lt: []const u8,
    new_lt: []const u8,
) !void {
    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = try loadLinksStructuralOnly(allocator, io, repo_root, &rep);
    defer loaded.deinit();

    if (!rep.isEmpty()) {
        const lp = try formatLinksRelPath(allocator, repo_root);
        defer allocator.free(lp);
        rep.print(lp);
        return error.LinksInvalid;
    }

    const cwd = Dir.cwd();

    var new_rows: std.ArrayList(LinkRowJson) = .empty;
    defer {
        for (new_rows.items) |row| {
            allocator.free(row.id);
            allocator.free(row.link_type);
            allocator.free(row.out);
            allocator.free(row.in);
            if (row.labels) |ls| {
                for (ls) |s| allocator.free(s);
                allocator.free(ls);
            }
        }
        new_rows.deinit(allocator);
    }

    for (loaded.rows()) |r| {
        if (!std.mem.eql(u8, r.link_type, old_lt)) {
            const id_c = try allocator.dupe(u8, r.id);
            errdefer allocator.free(id_c);
            const lt_c = try allocator.dupe(u8, r.link_type);
            errdefer allocator.free(lt_c);
            const o_c = try allocator.dupe(u8, r.out);
            errdefer allocator.free(o_c);
            const i_c = try allocator.dupe(u8, r.in);
            errdefer allocator.free(i_c);
            var labels_c: ?[][]const u8 = null;
            if (r.labels) |ls| {
                const copy = try allocator.alloc([]const u8, ls.len);
                errdefer allocator.free(copy);
                for (ls, 0..) |s, j| {
                    copy[j] = try allocator.dupe(u8, s);
                }
                labels_c = copy;
            }
            try new_rows.append(allocator, .{
                .id = id_c,
                .link_type = lt_c,
                .out = o_c,
                .in = i_c,
                .labels = labels_c,
            });
            continue;
        }

        const n = instance_id.parseSuffixAfterPrefix(r.id, old_lt) orelse return error.InvalidLinkName;
        const new_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ new_lt, n });
        const lt_c = try allocator.dupe(u8, new_lt);
        errdefer allocator.free(lt_c);
        const o_c = try allocator.dupe(u8, r.out);
        errdefer allocator.free(o_c);
        const i_c = try allocator.dupe(u8, r.in);
        errdefer allocator.free(i_c);
        var labels_c: ?[][]const u8 = null;
        if (r.labels) |ls| {
            const copy = try allocator.alloc([]const u8, ls.len);
            errdefer allocator.free(copy);
            for (ls, 0..) |s, j| {
                copy[j] = try allocator.dupe(u8, s);
            }
            labels_c = copy;
        }
        try new_rows.append(allocator, .{
            .id = new_id,
            .link_type = lt_c,
            .out = o_c,
            .in = i_c,
            .labels = labels_c,
        });

        const old_dir = try path_layout.linkInstanceDir(allocator, old_lt, r.id);
        defer allocator.free(old_dir);
        const old_abs = try std.fs.path.join(allocator, &.{ repo_root, old_dir });
        defer allocator.free(old_abs);
        const new_dir_rel = try path_layout.linkInstanceDir(allocator, new_lt, new_id);
        defer allocator.free(new_dir_rel);
        const new_dir = try std.fs.path.join(allocator, &.{ repo_root, new_dir_rel });
        defer allocator.free(new_dir);

        cwd.rename(old_abs, cwd, new_dir, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    try writeLinksAtomic(io, allocator, repo_root, new_rows.items);
}

/// Returns whether any non-tombstoned link row references `obj_prefix` on `in` or `out`.
pub fn hasDanglingLinksForPrefix(
    registry: *const fits_registry.Registry,
    loaded: *const LoadedLinks,
    obj_prefix: []const u8,
) bool {
    const one = [_][]const u8{obj_prefix};
    for (loaded.rows()) |row| {
        if (isDanglingRow(registry, row, &one)) return true;
    }
    return false;
}

/// Removes link rows whose endpoints use `obj_prefix` (skips tombstoned link ids).
///
/// Parameters:
/// - `preserve_local`: when true, keeps `links/<link-type>/<id>/` directories on disk.
///
/// Returns: number of rows removed.
pub fn removeDanglingLinksForPrefix(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    registry: *fits_registry.Registry,
    obj_prefix: []const u8,
    preserve_local: bool,
) !usize {
    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = try loadLinks(allocator, io, repo_root, registry, &rep);
    defer loaded.deinit();

    if (!rep.isEmpty()) {
        const lp = try formatLinksRelPath(allocator, repo_root);
        defer allocator.free(lp);
        rep.print(lp);
        return error.LinksInvalid;
    }

    const one = [_][]const u8{obj_prefix};
    var kept: std.ArrayList(LinkRowJson) = .empty;
    defer {
        for (kept.items) |row| freeLinkRow(allocator, row);
        kept.deinit(allocator);
    }

    var removed: usize = 0;
    const cwd = Dir.cwd();

    for (loaded.rows()) |r| {
        if (isDanglingRow(registry, r, &one)) {
            removed += 1;
            if (!preserve_local) {
                const payload_rel = try path_layout.linkInstanceDir(allocator, r.link_type, r.id);
                defer allocator.free(payload_rel);
                const payload_dir = try std.fs.path.join(allocator, &.{ repo_root, payload_rel });
                defer allocator.free(payload_dir);
                if (cwd.statFile(io, payload_dir, .{})) |_| {
                    try cwd.deleteTree(io, payload_dir);
                } else |_| {}
            }
            continue;
        }
        try kept.append(allocator, try duplicateLinkRow(allocator, r));
    }

    try writeLinksAtomic(io, allocator, repo_root, kept.items);
    return removed;
}

/// Drops non-tombstoned rows for `link_type` from `links.jsonc` and optional payload dirs.
pub fn removeLinkTypeFromIndex(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    registry: *fits_registry.Registry,
    link_type: []const u8,
    preserve_local: bool,
) !void {
    var rep = links_validate.ValidationReport{ .allocator = allocator };
    defer rep.deinit();

    var loaded = try loadLinks(allocator, io, repo_root, registry, &rep);
    defer loaded.deinit();

    if (!rep.isEmpty()) {
        const lp = try formatLinksRelPath(allocator, repo_root);
        defer allocator.free(lp);
        rep.print(lp);
        return error.LinksInvalid;
    }

    var kept: std.ArrayList(LinkRowJson) = .empty;
    defer {
        for (kept.items) |row| freeLinkRow(allocator, row);
        kept.deinit(allocator);
    }

    const cwd = Dir.cwd();

    for (loaded.rows()) |r| {
        if (std.mem.eql(u8, r.link_type, link_type)) {
            const parsed_n = instance_id.parseSuffixAfterPrefix(r.id, link_type) orelse continue;
            if (registry.isLinkTombstoned(link_type, parsed_n)) continue;
            if (!preserve_local) {
                const payload_rel = try path_layout.linkInstanceDir(allocator, link_type, r.id);
                defer allocator.free(payload_rel);
                const payload_dir = try std.fs.path.join(allocator, &.{ repo_root, payload_rel });
                defer allocator.free(payload_dir);
                if (cwd.statFile(io, payload_dir, .{})) |_| {
                    try cwd.deleteTree(io, payload_dir);
                } else |_| {}
            }
            continue;
        }
        try kept.append(allocator, try duplicateLinkRow(allocator, r));
    }

    try writeLinksAtomic(io, allocator, repo_root, kept.items);

    if (!preserve_local) {
        const type_dir_rel = try path_layout.linkTypeDir(allocator, link_type);
        defer allocator.free(type_dir_rel);
        const type_dir_abs = try std.fs.path.join(allocator, &.{ repo_root, type_dir_rel });
        defer allocator.free(type_dir_abs);
        var dir = cwd.openDir(io, type_dir_abs, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const parsed_n = instance_id.parseSuffixAfterPrefix(entry.name, link_type) orelse continue;
            if (registry.isLinkTombstoned(link_type, parsed_n)) continue;
            const full = try std.fs.path.join(allocator, &.{ type_dir_abs, entry.name });
            defer allocator.free(full);
            try cwd.deleteTree(io, full);
        }
    }
}

fn isDanglingRow(
    registry: *const fits_registry.Registry,
    row: LinkRowJson,
    obj_prefixes: []const []const u8,
) bool {
    const parsed_n = instance_id.parseSuffixAfterPrefix(row.id, row.link_type) orelse return false;
    if (registry.isLinkTombstoned(row.link_type, parsed_n)) return false;

    if (instance_id.parseNodeName(row.in, obj_prefixes)) |_| return true;
    if (instance_id.parseNodeName(row.out, obj_prefixes)) |_| return true;
    return false;
}

fn duplicateLinkRow(allocator: std.mem.Allocator, r: LinkRowJson) !LinkRowJson {
    const id_c = try allocator.dupe(u8, r.id);
    errdefer allocator.free(id_c);
    const lt_c = try allocator.dupe(u8, r.link_type);
    errdefer allocator.free(lt_c);
    const o_c = try allocator.dupe(u8, r.out);
    errdefer allocator.free(o_c);
    const i_c = try allocator.dupe(u8, r.in);
    errdefer allocator.free(i_c);
    var labels_c: ?[][]const u8 = null;
    if (r.labels) |ls| {
        const copy = try allocator.alloc([]const u8, ls.len);
        errdefer allocator.free(copy);
        for (ls, 0..) |s, j| {
            copy[j] = try allocator.dupe(u8, s);
        }
        labels_c = copy;
    }
    return .{
        .id = id_c,
        .link_type = lt_c,
        .out = o_c,
        .in = i_c,
        .labels = labels_c,
    };
}

fn freeLinkRow(allocator: std.mem.Allocator, row: LinkRowJson) void {
    allocator.free(row.id);
    allocator.free(row.link_type);
    allocator.free(row.out);
    allocator.free(row.in);
    if (row.labels) |ls| {
        for (ls) |s| allocator.free(s);
        allocator.free(ls);
    }
}

/// Serializes `rows` into `links/links.jsonc` atomically (JSON, no comments).
pub fn writeLinksAtomic(io: Io, allocator: std.mem.Allocator, repo_root: []const u8, links_rows: []const LinkRowJson) !void {
    const cwd = Dir.cwd();
    const path = try joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse links_dir_name;
    if (std.fs.path.isAbsolute(parent)) {
        try cwd.createDirPath(io, parent);
    } else {
        try cwd.createDirPath(io, parent);
    }

    const env = LinksEnvelope{
        .description = links_validate.links_description,
        .version = 1,
        .kind = links_validate.links_kind,
        .links = links_rows,
    };

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &json_out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(env);
    const json_slice = json_out.written();

    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);

    {
        var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, json_slice);
        try out.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}
