//! Structural validation for [`relations/links.jsonc`] after JSONC comments are stripped.
//! Semantic checks against `.fits/registry.json` live in [`validateLinksAgainstRegistryRows`].

const std = @import("std");

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const fits_registry = @import("fits_registry.zig");
const instance_id = @import("../../domain/instance_id.zig");

pub const schema_json = @embedFile("../../schemas/links.schema.json");

pub const links_kind: []const u8 = "fits-links-v1";

pub const links_description: []const u8 =
    "Directed links between issued object ids. Edit by hand or via fits CLI; validate with fits validate.";

pub const ValidationIssue = struct {
    path: []const u8,
    message: []const u8,
};

// Samples link `id` fields for duplicate detection after structural parsing.
const LinkIdSample = struct {
    idx: usize,
    id: []const u8,
};

pub const ValidationReport = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList(ValidationIssue) = .empty,

    pub fn isEmpty(self: *const ValidationReport) bool {
        return self.issues.items.len == 0;
    }

    pub fn deinit(self: *ValidationReport) void {
        for (self.issues.items) |issue| {
            self.allocator.free(issue.path);
            self.allocator.free(issue.message);
        }
        self.issues.deinit(self.allocator);
    }

    pub fn print(self: *const ValidationReport, links_path: []const u8) void {
        for (self.issues.items) |issue| {
            std.debug.print("{s}: at {s}: {s}\n", .{ links_path, issue.path, issue.message });
        }
    }
};

/// Appends copies of every issue from `src` into `dst`.
pub fn appendReport(dst: *ValidationReport, src: *const ValidationReport) !void {
    for (src.issues.items) |issue| {
        const p = try dst.allocator.dupe(u8, issue.path);
        errdefer dst.allocator.free(p);
        const m = try dst.allocator.dupe(u8, issue.message);
        try dst.issues.append(dst.allocator, .{ .path = p, .message = m });
    }
}

pub fn validateLinksDocument(allocator: std.mem.Allocator, contents: []const u8) !ValidationReport {
    var report = ValidationReport{ .allocator = allocator };

    var parsed = std.json.parseFromSlice(JsonValue, allocator, contents, .{}) catch |err| {
        const msg = try formatJsonParseError(allocator, err);
        defer allocator.free(msg);
        try pushIssue(&report, "$", msg);
        return report;
    };
    defer parsed.deinit();

    validateEnvelope(&report, "$", parsed.value);
    return report;
}

fn validateEnvelope(report: *ValidationReport, path: []const u8, value: JsonValue) void {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            pushIssueStatic(report, path, "must be a JSON object");
            return;
        },
    };

    const allowed_top = [_][]const u8{ "description", "version", "kind", "links" };
    const required_top = [_][]const u8{ "description", "version", "kind", "links" };
    checkObjectShape(report, path, obj, &allowed_top, &required_top);

    if (obj.get("description")) |dv| validateLinksDescription(report, path, dv);
    if (obj.get("kind")) |kv| validateLinksKind(report, path, kv);
    if (obj.get("version")) |vv| validateVersion(report, path, vv);

    const links_val = obj.get("links");
    const links_arr: ?std.json.Array = if (links_val) |lv| switch (lv) {
        .array => |a| a,
        else => blk: {
            const p = joinPath(report.allocator, path, "links") catch break :blk null;
            defer report.allocator.free(p);
            pushIssueStatic(report, p, "must be an array");
            break :blk null;
        },
    } else null;

    if (links_arr) |arr| validateLinksArray(report, path, arr);
}

fn validateLinksDescription(report: *ValidationReport, base_path: []const u8, value: JsonValue) void {
    const p = formatFieldPath(report, base_path, "description") catch return;
    defer report.allocator.free(p);

    const actual = switch (value) {
        .string => |s| s,
        else => {
            pushIssueStatic(report, p, "must be a string");
            return;
        },
    };

    if (!std.mem.eql(u8, actual, links_description)) {
        pushIssueStatic(report, p, "must be the canonical fits links description written by fits CLI");
    }
}

fn validateLinksKind(report: *ValidationReport, base_path: []const u8, value: JsonValue) void {
    const p = formatFieldPath(report, base_path, "kind") catch return;
    defer report.allocator.free(p);

    const actual = switch (value) {
        .string => |s| s,
        else => {
            pushIssueStatic(report, p, "must be a string");
            return;
        },
    };

    if (!std.mem.eql(u8, actual, links_kind)) {
        const msg = std.fmt.allocPrint(report.allocator, "must be \"{s}\", got \"{s}\"", .{ links_kind, actual }) catch return;
        pushIssueOwned(report, p, msg);
    }
}

fn validateVersion(report: *ValidationReport, base_path: []const u8, value: JsonValue) void {
    const p = formatFieldPath(report, base_path, "version") catch return;
    defer report.allocator.free(p);

    const n = readPositiveInt(report, p, value) orelse return;
    if (n != 1) {
        const msg = std.fmt.allocPrint(report.allocator, "unsupported links document version {d} (supported: 1)", .{n}) catch return;
        pushIssueOwned(report, p, msg);
    }
}

fn validateLinksArray(report: *ValidationReport, base_path: []const u8, links: std.json.Array) void {
    var id_samples = std.ArrayListUnmanaged(LinkIdSample).empty;
    defer id_samples.deinit(report.allocator);

    for (links.items, 0..) |entry, i| {
        const lp = formatIndexedPath(report, base_path, "links", i) catch return;
        defer report.allocator.free(lp);

        const obj = switch (entry) {
            .object => |o| o,
            else => {
                pushIssueStatic(report, lp, "must be a JSON object");
                continue;
            },
        };

        const allowed = [_][]const u8{ "id", "link_type", "out", "in", "labels" };
        const required = [_][]const u8{ "id", "link_type", "out", "in" };
        checkObjectShape(report, lp, obj, &allowed, &required);

        if (obj.get("id")) |iv| validateLinkIdField(report, lp, "id", iv);
        if (obj.get("link_type")) |tv| validatePrefixLikeField(report, lp, "link_type", tv);
        if (obj.get("out")) |ov| validateCanonicalObjIdField(report, lp, "out", ov);
        if (obj.get("in")) |nv| validateCanonicalObjIdField(report, lp, "in", nv);
        if (obj.get("labels")) |lv| validateLabelsArray(report, lp, lv);

        if (objString(obj.get("id"))) |sid| {
            id_samples.append(report.allocator, .{ .idx = i, .id = sid }) catch return;
        }
    }

    std.mem.sortUnstable(
        LinkIdSample,
        id_samples.items,
        {},
        struct {
            fn less(_: void, a: LinkIdSample, b: LinkIdSample) bool {
                const ord = std.mem.order(u8, a.id, b.id);
                if (ord == .lt) return true;
                if (ord == .gt) return false;
                return a.idx < b.idx;
            }
        }.less,
    );

    if (id_samples.items.len < 2) return;

    for (id_samples.items[1..], 1..) |sample, k| {
        if (std.mem.eql(u8, sample.id, id_samples.items[k - 1].id)) {
            const dup_idx = sample.idx;
            const lp = formatIndexedPath(report, base_path, "links", dup_idx) catch return;
            defer report.allocator.free(lp);
            const fp = formatFieldPath(report, lp, "id") catch return;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "duplicate link id");
        }
    }
}

fn validateLabelsArray(report: *ValidationReport, link_path: []const u8, value: JsonValue) void {
    const p = formatFieldPath(report, link_path, "labels") catch return;
    defer report.allocator.free(p);

    const arr = switch (value) {
        .array => |a| a,
        else => {
            pushIssueStatic(report, p, "must be an array");
            return;
        },
    };

    for (arr.items, 0..) |entry, i| {
        const ip = formatIndexedPath(report, link_path, "labels", i) catch return;
        defer report.allocator.free(ip);

        switch (entry) {
            .string => {},
            else => pushIssueStatic(report, ip, "must be a string"),
        }
    }
}

fn validateCanonicalObjIdField(report: *ValidationReport, link_path: []const u8, field: []const u8, value: JsonValue) void {
    const fp = formatFieldPath(report, link_path, field) catch return;
    defer report.allocator.free(fp);

    const s = switch (value) {
        .string => |str| str,
        else => {
            pushIssueStatic(report, fp, "must be a string");
            return;
        },
    };

    validateCanonicalObjIdString(report, fp, s);
}

fn validateCanonicalObjIdString(report: *ValidationReport, fp: []const u8, s: []const u8) void {
    if (s.len == 0) {
        pushIssueStatic(report, fp, "must be a non-empty canonical object id");
        return;
    }
    var dash: ?usize = null;
    for (s, 0..) |c, idx| {
        if (c == '-') {
            dash = idx;
            break;
        }
    }
    const di = dash orelse {
        pushIssueStatic(report, fp, "must look like PREFIX-n");
        return;
    };
    if (di == 0 or di == s.len - 1) {
        pushIssueStatic(report, fp, "must look like PREFIX-n");
        return;
    }
    const prefix_part = s[0..di];
    validatePrefixChars(report, fp, prefix_part);
    const num_part = s[di + 1 ..];
    if (num_part.len == 0 or num_part[0] == '0') {
        pushIssueStatic(report, fp, "numeric suffix must be a positive decimal without leading zeros");
        return;
    }
    for (num_part) |c| {
        if (!std.ascii.isDigit(c)) {
            pushIssueStatic(report, fp, "numeric suffix must be decimal digits");
            return;
        }
    }
}

fn validateLinkIdField(report: *ValidationReport, link_path: []const u8, field: []const u8, value: JsonValue) void {
    const fp = formatFieldPath(report, link_path, field) catch return;
    defer report.allocator.free(fp);

    const s = switch (value) {
        .string => |str| str,
        else => {
            pushIssueStatic(report, fp, "must be a string");
            return;
        },
    };

    validateCanonicalObjIdString(report, fp, s);
}

fn validatePrefixLikeField(report: *ValidationReport, link_path: []const u8, field: []const u8, value: JsonValue) void {
    const fp = formatFieldPath(report, link_path, field) catch return;
    defer report.allocator.free(fp);

    const s = switch (value) {
        .string => |str| str,
        else => {
            pushIssueStatic(report, fp, "must be a string");
            return;
        },
    };

    validatePrefixChars(report, fp, s);
}

fn validatePrefixChars(report: *ValidationReport, fp: []const u8, s: []const u8) void {
    validateObjPrefixString(s) catch {
        pushIssueStatic(
            report,
            fp,
            "must match prefix rules (ASCII letter, then letters, digits, or underscore)",
        );
    };
}

fn validateObjPrefixString(obj_prefix: []const u8) error{Invalid}!void {
    if (obj_prefix.len == 0) return error.Invalid;
    const c0 = obj_prefix[0];
    if (!std.ascii.isAlphabetic(c0)) return error.Invalid;
    for (obj_prefix[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return error.Invalid;
    }
}

fn objString(val: ?JsonValue) ?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn checkObjectShape(
    report: *ValidationReport,
    path: []const u8,
    obj: ObjectMap,
    allowed: []const []const u8,
    required: []const []const u8,
) void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!containsStr(allowed, entry.key_ptr.*)) {
            const msg = std.fmt.allocPrint(report.allocator, "unknown property \"{s}\"", .{entry.key_ptr.*}) catch return;
            const field_path = formatFieldPath(report, path, entry.key_ptr.*) catch return;
            defer report.allocator.free(field_path);
            pushIssueOwned(report, field_path, msg);
        }
    }

    for (required) |key| {
        if (obj.get(key) == null) {
            const msg = std.fmt.allocPrint(report.allocator, "missing required property \"{s}\"", .{key}) catch return;
            const field_path = formatFieldPath(report, path, key) catch return;
            defer report.allocator.free(field_path);
            pushIssueOwned(report, field_path, msg);
        }
    }
}

fn readPositiveInt(report: *ValidationReport, field_path: []const u8, value: JsonValue) ?u64 {
    const n: i128 = switch (value) {
        .integer => |i| i,
        else => {
            pushIssueStatic(report, field_path, "must be an integer >= 1");
            return null;
        },
    };

    if (n < 1) {
        pushIssueStatic(report, field_path, "must be an integer >= 1");
        return null;
    }
    if (n > std.math.maxInt(u64)) return null;
    return @intCast(n);
}

fn formatJsonParseError(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
}

pub fn pushIssue(report: *ValidationReport, path: []const u8, message: []const u8) !void {
    const path_copy = try report.allocator.dupe(u8, path);
    const msg_copy = try report.allocator.dupe(u8, message);
    errdefer report.allocator.free(path_copy);
    errdefer report.allocator.free(msg_copy);
    try report.issues.append(report.allocator, .{ .path = path_copy, .message = msg_copy });
}

fn pushIssueStatic(report: *ValidationReport, path: []const u8, message: []const u8) void {
    const path_copy = report.allocator.dupe(u8, path) catch return;
    const msg_copy = report.allocator.dupe(u8, message) catch {
        report.allocator.free(path_copy);
        return;
    };
    report.issues.append(report.allocator, .{ .path = path_copy, .message = msg_copy }) catch {
        report.allocator.free(path_copy);
        report.allocator.free(msg_copy);
    };
}

fn pushIssueOwned(report: *ValidationReport, path: []const u8, message: []const u8) void {
    const path_copy = report.allocator.dupe(u8, path) catch {
        report.allocator.free(message);
        return;
    };
    report.issues.append(report.allocator, .{ .path = path_copy, .message = message }) catch {
        report.allocator.free(path_copy);
        report.allocator.free(message);
    };
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, "$")) {
        return std.fmt.allocPrint(allocator, "$.{s}", .{suffix});
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, suffix });
}

fn formatFieldPath(report: *ValidationReport, base: []const u8, field: []const u8) ![]const u8 {
    return joinPath(report.allocator, base, field);
}

fn formatIndexedPath(report: *ValidationReport, base: []const u8, field: []const u8, index: usize) ![]const u8 {
    if (std.mem.eql(u8, base, "$")) {
        return std.fmt.allocPrint(report.allocator, "$.{s}[{d}]", .{ field, index });
    }
    return std.fmt.allocPrint(report.allocator, "{s}.{s}[{d}]", .{ base, field, index });
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

pub const LinkRowView = struct {
    id: []const u8,
    link_type: []const u8,
    out: []const u8,
    in: []const u8,
};

/// Validates registry consistency for parsed link rows (after structural validation).
///
/// Parameters:
/// - `report`: Semantic findings appended here (caller may reuse structural report).
/// - `registry`: Loaded `.fits/registry.json`.
/// - `rows`: Borrowed rows from the typed links parse.
pub fn validateLinksAgainstRegistryRows(
    report: *ValidationReport,
    registry: *const fits_registry.Registry,
    rows: []const LinkRowView,
) void {
    const obj_prefix_buf = registry.objPrefixSlice(report.allocator) catch return;
    defer report.allocator.free(obj_prefix_buf);

    for (rows, 0..) |row, i| {
        const lp = formatIndexedPath(report, "$", "links", i) catch return;
        defer report.allocator.free(lp);

        if (!registry.hasLinkType(row.link_type)) {
            const fp = formatFieldPath(report, lp, "link_type") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "unknown link_type (not registered in .fits/registry.json)");
            continue;
        }

        const expected_in = registry.linkTypeInPrefix(row.link_type).?;
        const expected_out = registry.linkTypeOutPrefix(row.link_type).?;

        const parsed_link_n = instance_id.parseSuffixAfterPrefix(row.id, row.link_type) orelse {
            const fp = formatFieldPath(report, lp, "id") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "id must be \"{LINK_TYPE}-n\" matching link_type");
            continue;
        };

        const next_lt = registry.nextForLinkType(row.link_type).?;
        if (parsed_link_n == 0 or parsed_link_n >= next_lt) {
            const fp = formatFieldPath(report, lp, "id") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "link numeric suffix is not in issued range for this link_type");
            continue;
        }

        if (registry.isLinkTombstoned(row.link_type, parsed_link_n)) {
            const fp = formatFieldPath(report, lp, "id") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "link id is tombstoned");
            continue;
        }

        const po = instance_id.parseNodeName(row.out, obj_prefix_buf) orelse {
            const fp = formatFieldPath(report, lp, "out") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "out is not a canonical issued node id");
            continue;
        };
        if (!std.mem.eql(u8, po.node_prefix, expected_out)) {
            const fp = formatFieldPath(report, lp, "out") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "out node-type prefix does not match registered out_obj_prefix for this link_type");
            continue;
        }

        const pi = instance_id.parseNodeName(row.in, obj_prefix_buf) orelse {
            const fp = formatFieldPath(report, lp, "in") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "in is not a canonical issued node id");
            continue;
        };
        if (!std.mem.eql(u8, pi.node_prefix, expected_in)) {
            const fp = formatFieldPath(report, lp, "in") catch continue;
            defer report.allocator.free(fp);
            pushIssueStatic(report, fp, "in node-type prefix does not match registered in_obj_prefix for this link_type");
            continue;
        }

        validateIssuedObj(report, lp, "out", registry, po.node_prefix, po.n);
        validateIssuedObj(report, lp, "in", registry, pi.node_prefix, pi.n);
    }
}

fn validateIssuedObj(
    report: *ValidationReport,
    link_path: []const u8,
    field: []const u8,
    registry: *const fits_registry.Registry,
    obj_prefix: []const u8,
    n: u64,
) void {
    const fp = formatFieldPath(report, link_path, field) catch return;
    defer report.allocator.free(fp);

    const next_o = registry.nextForObjPrefix(obj_prefix) orelse {
        pushIssueStatic(report, fp, "unknown object prefix");
        return;
    };
    if (n == 0 or n >= next_o) {
        pushIssueStatic(report, fp, "object id is not in issued range");
        return;
    }
    if (registry.isTombstoned(obj_prefix, n)) {
        pushIssueStatic(report, fp, "object id is tombstoned");
    }
}

test "validateLinksDocument accepts minimal links file" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Directed links between issued object ids. Edit by hand or via fits CLI; validate with fits validate.",
        \\  "version": 1,
        \\  "kind": "fits-links-v1",
        \\  "links": []
        \\}
    ;

    var report = try validateLinksDocument(alloc, json);
    defer report.deinit();
    try std.testing.expect(report.isEmpty());
}

test "links schema embedded" {
    try std.testing.expect(std.mem.indexOf(u8, schema_json, "fits-links-v1") != null);
}
