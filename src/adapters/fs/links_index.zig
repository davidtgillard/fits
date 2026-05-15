//! Loads, validates, and writes [`relations/links.jsonc`].

const std = @import("std");
const fits_registry = @import("fits_registry.zig");
const jsonc_strip = @import("jsonc_strip.zig");
const links_validate = @import("links_validate.zig");
const instance_id = @import("../../domain/instance_id.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Directory under the repo root holding `links.jsonc` and optional per-link folders.
pub const relations_dir_name: []const u8 = "relations";

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

/// Joins `repo_root/relations/links.jsonc` (caller frees).
pub fn joinLinksAbsPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, relations_dir_name, links_file_name });
}

/// Display path when reporting issues (e.g. `relations/links.jsonc`).
pub fn formatLinksRelPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    if (std.mem.eql(u8, repo_root, ".")) {
        return std.fs.path.join(allocator, &.{ relations_dir_name, links_file_name });
    }
    return std.fs.path.join(allocator, &.{ repo_root, relations_dir_name, links_file_name });
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
        allocator.free(stripped);
        return error.LinksInvalid;
    }

    const parsed = std.json.parseFromSlice(LinksEnvelope, allocator, stripped, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try links_validate.pushIssue(report, "$", msg);
        allocator.free(stripped);
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
        allocator.free(stripped);
        return error.LinksInvalid;
    }

    const parsed = std.json.parseFromSlice(LinksEnvelope, allocator, stripped, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try links_validate.pushIssue(report, "$", msg);
        allocator.free(stripped);
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

        const old_dir = try std.fs.path.join(allocator, &.{ repo_root, relations_dir_name, r.id });
        defer allocator.free(old_dir);
        const new_dir = try std.fs.path.join(allocator, &.{ repo_root, relations_dir_name, new_id });
        defer allocator.free(new_dir);

        cwd.rename(old_dir, cwd, new_dir, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    try writeLinksAtomic(io, allocator, repo_root, new_rows.items);
}

/// Serializes `rows` into `relations/links.jsonc` atomically (JSON, no comments).
pub fn writeLinksAtomic(io: Io, allocator: std.mem.Allocator, repo_root: []const u8, links_rows: []const LinkRowJson) !void {
    const cwd = Dir.cwd();
    const rel_dir = try std.fs.path.join(allocator, &.{ repo_root, relations_dir_name });
    defer allocator.free(rel_dir);
    try cwd.createDirPath(io, rel_dir);

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

    const path = try joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(path);
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
