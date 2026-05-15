//! Structural validation for `.fits/registry.json` aligned with `schemas/registry.schema.json`
//! (embedded copy under `src/schemas/` for `@embedFile`).
//! Collects every issue in one pass with human-readable paths and messages.

const std = @import("std");

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Embedded schema (contract for tooling and drift tests).
pub const schema_json = @embedFile("../../schemas/registry.schema.json");

pub const registry_kind: []const u8 = "fits-registry-v1";

/// Human-readable notice written at the top of every registry file by [`Registry.save`].
pub const registry_description: []const u8 =
    "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.";

/// One validation finding with a JSON-pointer-like path and message.
pub const ValidationIssue = struct {
    path: []const u8,
    message: []const u8,
};

/// Collected validation findings; caller must [`deinit`] when done.
pub const ValidationReport = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList(ValidationIssue) = .empty,

    /// Returns whether the report contains no issues.
    pub fn isEmpty(self: *const ValidationReport) bool {
        return self.issues.items.len == 0;
    }

    /// Frees issue strings and the issues list.
    pub fn deinit(self: *ValidationReport) void {
        for (self.issues.items) |issue| {
            self.allocator.free(issue.path);
            self.allocator.free(issue.message);
        }
        self.issues.deinit(self.allocator);
    }

    /// Prints `{registry_path}: at {path}: {message}` per issue to stderr.
    pub fn print(self: *const ValidationReport, registry_path: []const u8) void {
        for (self.issues.items) |issue| {
            std.debug.print("{s}: at {s}: {s}\n", .{ registry_path, issue.path, issue.message });
        }
    }
};

/// Validates raw registry JSON text; always returns an owned report (possibly empty).
///
/// Parameters:
/// - `allocator`: Used for the report and duplicated path/message strings.
/// - `contents`: Full file contents of `registry.json`.
///
/// Returns: a [`ValidationReport`] the caller must [`ValidationReport.deinit`].
pub fn validateRegistryDocument(allocator: std.mem.Allocator, contents: []const u8) !ValidationReport {
    var report = ValidationReport{ .allocator = allocator };

    var parsed = std.json.parseFromSlice(JsonValue, allocator, contents, .{}) catch |err| {
        const msg = try formatJsonParseError(allocator, err);
        defer allocator.free(msg);
        try pushIssue(&report, "$", msg);
        return report;
    };
    defer parsed.deinit();

    validateValue(&report, "$", parsed.value);
    return report;
}

fn validateValue(report: *ValidationReport, path: []const u8, value: JsonValue) void {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            pushIssueStatic(report, path, "must be a JSON object");
            return;
        },
    };

    const allowed_top = [_][]const u8{ "description", "version", "kind", "prefixes" };
    const required_top = [_][]const u8{ "description", "version", "kind", "prefixes" };
    checkObjectShape(report, path, obj, &allowed_top, &required_top);

    if (obj.get("description")) |dv| {
        validateDescription(report, path, dv);
    }

    const version_val = obj.get("version");
    const kind_val = obj.get("kind");
    const prefixes_val = obj.get("prefixes");

    if (version_val) |v| {
        _ = readVersion(report, path, v);
    }

    if (kind_val) |kv| {
        validateKind(report, path, kv);
    }

    const prefixes_array: ?std.json.Array = if (prefixes_val) |pv| switch (pv) {
        .array => |a| a,
        else => blk: {
            const prefixes_path = joinPath(report.allocator, path, "prefixes") catch break :blk null;
            defer report.allocator.free(prefixes_path);
            pushIssueStatic(report, prefixes_path, "must be an array");
            break :blk null;
        },
    } else null;

    if (prefixes_array) |prefixes| {
        validatePrefixes(report, path, prefixes);
    }
}

fn validateDescription(report: *ValidationReport, base_path: []const u8, value: JsonValue) void {
    const desc_path = formatFieldPath(report, base_path, "description") catch return;
    defer report.allocator.free(desc_path);

    const actual = switch (value) {
        .string => |s| s,
        else => {
            pushIssueStatic(report, desc_path, "must be a string");
            return;
        },
    };

    if (!std.mem.eql(u8, actual, registry_description)) {
        pushIssueStatic(report, desc_path, "must be the canonical FITS registry description written by the CLI");
    }
}

fn validateKind(report: *ValidationReport, base_path: []const u8, value: JsonValue) void {
    const kind_path = formatFieldPath(report, base_path, "kind") catch return;
    defer report.allocator.free(kind_path);

    const actual = switch (value) {
        .string => |s| s,
        else => {
            pushIssueStatic(report, kind_path, "must be a string");
            return;
        },
    };

    if (!std.mem.eql(u8, actual, registry_kind)) {
        const msg = std.fmt.allocPrint(report.allocator, "must be \"{s}\", got \"{s}\"", .{ registry_kind, actual }) catch return;
        pushIssueOwned(report, kind_path, msg);
    }
}

fn validatePrefixes(report: *ValidationReport, base_path: []const u8, prefixes: std.json.Array) void {
    for (prefixes.items, 0..) |entry, i| {
        const prefix_path = formatIndexedPath(report, base_path, "prefixes", i) catch return;
        defer report.allocator.free(prefix_path);

        const obj = switch (entry) {
            .object => |o| o,
            else => {
                pushIssueStatic(report, prefix_path, "must be a JSON object");
                continue;
            },
        };

        validatePrefixObject(report, prefix_path, obj);
    }
}

fn validatePrefixObject(report: *ValidationReport, prefix_path: []const u8, obj: ObjectMap) void {
    const allowed = [_][]const u8{ "obj_prefix", "next", "tombstones" };
    const required = [_][]const u8{ "obj_prefix", "next" };
    checkObjectShape(report, prefix_path, obj, &allowed, &required);

    if (obj.get("obj_prefix")) |pv| validateObjPrefixField(report, prefix_path, "obj_prefix", pv);
    if (obj.get("next")) |nv| validateNextField(report, prefix_path, "next", nv);
    if (obj.get("tombstones")) |tv| validateTombstonesArray(report, prefix_path, tv);
}

fn validateTombstonesArray(report: *ValidationReport, prefix_path: []const u8, value: JsonValue) void {
    const ts_path = formatFieldPath(report, prefix_path, "tombstones") catch return;
    defer report.allocator.free(ts_path);

    const arr = switch (value) {
        .array => |a| a,
        else => {
            pushIssueStatic(report, ts_path, "must be an array");
            return;
        },
    };

    const allowed = [_][]const u8{ "n", "git_commit" };
    const required = [_][]const u8{"n"};

    for (arr.items, 0..) |entry, i| {
        const tomb_path = formatIndexedPath(report, prefix_path, "tombstones", i) catch return;
        defer report.allocator.free(tomb_path);

        const obj = switch (entry) {
            .object => |o| o,
            else => {
                pushIssueStatic(report, tomb_path, "must be a JSON object");
                continue;
            },
        };

        checkObjectShape(report, tomb_path, obj, &allowed, &required);

        if (obj.get("n")) |nv| validateTombstoneN(report, tomb_path, nv);
        if (obj.get("git_commit")) |gv| validateGitCommitField(report, tomb_path, gv);
    }
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

fn validateObjPrefixField(report: *ValidationReport, base_path: []const u8, field: []const u8, value: JsonValue) void {
    const field_path = formatFieldPath(report, base_path, field) catch return;
    defer report.allocator.free(field_path);

    const s = switch (value) {
        .string => |str| str,
        else => {
            pushIssueStatic(report, field_path, "must be a string");
            return;
        },
    };

    validateObjPrefixString(s) catch {
        pushIssueStatic(
            report,
            field_path,
            "must match object prefix rules (ASCII letter, then letters, digits, or underscore)",
        );
    };
}

fn validateNextField(report: *ValidationReport, base_path: []const u8, field: []const u8, value: JsonValue) void {
    const field_path = formatFieldPath(report, base_path, field) catch return;
    defer report.allocator.free(field_path);
    validatePositiveInteger(report, field_path, value, "next");
}

fn validateTombstoneN(report: *ValidationReport, tomb_path: []const u8, value: JsonValue) void {
    const field_path = formatFieldPath(report, tomb_path, "n") catch return;
    defer report.allocator.free(field_path);
    validatePositiveInteger(report, field_path, value, "n");
}

fn validateGitCommitField(report: *ValidationReport, tomb_path: []const u8, value: JsonValue) void {
    const field_path = formatFieldPath(report, tomb_path, "git_commit") catch return;
    defer report.allocator.free(field_path);

    switch (value) {
        .null => return,
        .string => |s| {
            validateGitCommitString(s) catch {
                const msg = std.fmt.allocPrint(
                    report.allocator,
                    "must be 40 hexadecimal characters, got length {d}",
                    .{s.len},
                ) catch return;
                pushIssueOwned(report, field_path, msg);
            };
        },
        else => pushIssueStatic(report, field_path, "must be a string"),
    }
}

fn validatePositiveInteger(report: *ValidationReport, field_path: []const u8, value: JsonValue, label: []const u8) void {
    const n = readPositiveInteger(report, field_path, value) orelse return;
    _ = n;
    _ = label;
}

fn readVersion(report: *ValidationReport, base_path: []const u8, value: JsonValue) ?u32 {
    const version_path = formatFieldPath(report, base_path, "version") catch return null;
    defer report.allocator.free(version_path);

    const n = readPositiveInteger(report, version_path, value) orelse return null;

    if (n == 1) return 1;

    const msg = std.fmt.allocPrint(
        report.allocator,
        "unsupported registry version {d} (supported: 1)",
        .{n},
    ) catch return null;
    pushIssueOwned(report, version_path, msg);
    return null;
}

fn readPositiveInteger(report: *ValidationReport, field_path: []const u8, value: JsonValue) ?u64 {
    const n: i128 = switch (value) {
        .integer => |i| i,
        .float => |f| blk: {
            if (f != @floor(f)) {
                pushIssueStatic(report, field_path, "must be an integer >= 1");
                return null;
            }
            const as_int: i128 = @intFromFloat(f);
            if (@as(f64, @floatFromInt(as_int)) != f) {
                pushIssueStatic(report, field_path, "must be an integer >= 1");
                return null;
            }
            break :blk as_int;
        },
        .number_string => |s| std.fmt.parseInt(i128, s, 10) catch {
            pushIssueStatic(report, field_path, "must be an integer >= 1");
            return null;
        },
        else => {
            pushIssueStatic(report, field_path, "must be an integer >= 1");
            return null;
        },
    };

    if (n < 1) {
        const msg = std.fmt.allocPrint(report.allocator, "must be an integer >= 1, got {d}", .{n}) catch return null;
        pushIssueOwned(report, field_path, msg);
        return null;
    }

    if (n > std.math.maxInt(u64)) {
        pushIssueStatic(report, field_path, "integer value is too large");
        return null;
    }

    return @intCast(n);
}

fn formatJsonParseError(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(allocator, "invalid JSON: {s}", .{@errorName(err)});
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

fn pushIssue(report: *ValidationReport, path: []const u8, message: []const u8) !void {
    const path_copy = try report.allocator.dupe(u8, path);
    const msg_copy = try report.allocator.dupe(u8, message);
    errdefer report.allocator.free(path_copy);
    errdefer report.allocator.free(msg_copy);
    try report.issues.append(report.allocator, .{ .path = path_copy, .message = msg_copy });
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

fn validateObjPrefixString(obj_prefix: []const u8) error{InvalidObjPrefix}!void {
    if (obj_prefix.len == 0) return error.InvalidObjPrefix;
    const c0 = obj_prefix[0];
    if (!std.ascii.isAlphabetic(c0)) return error.InvalidObjPrefix;
    for (obj_prefix[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return error.InvalidObjPrefix;
    }
}

fn validateGitCommitString(commit: []const u8) error{InvalidGitCommit}!void {
    if (commit.len != 40) return error.InvalidGitCommit;
    for (commit) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidGitCommit;
    }
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

test "validateRegistryDocument reports multiple issues" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": 3,
        \\  "kind": "wrong",
        \\  "prefixes": [
        \\    { "obj_prefix": "9X", "next": 0, "tombstones": [{ "n": 0, "git_commit": "short" }] },
        \\    { "obj_prefix": "REQ", "next": 1, "extra": true }
        \\  ],
        \\  "extra_field": true
        \\}
    ;

    var report = try validateRegistryDocument(alloc, json);
    defer report.deinit();

    try std.testing.expect(report.issues.items.len >= 5);
}

test "validateRegistryDocument accepts valid registry" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [{
        \\    "obj_prefix": "REQ",
        \\    "next": 2,
        \\    "tombstones": [{ "n": 1, "git_commit": "a1b2c3d4e5f6789012345678901234567890abcd" }]
        \\  }]
        \\}
    ;

    var report = try validateRegistryDocument(alloc, json);
    defer report.deinit();
    try std.testing.expect(report.isEmpty());
}

test "validateRegistryDocument obj_prefix and next errors" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [{ "obj_prefix": "9A", "next": 0 }]
        \\}
    ;

    var report = try validateRegistryDocument(alloc, json);
    defer report.deinit();
    try std.testing.expect(report.issues.items.len >= 2);
}

test "validateRegistryDocument rejects legacy slug field" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
        \\  "version": 1,
        \\  "kind": "fits-registry-v1",
        \\  "prefixes": [{ "slug": "REQ", "next": 1 }]
        \\}
    ;

    var report = try validateRegistryDocument(alloc, json);
    defer report.deinit();
    try std.testing.expect(!report.isEmpty());
}

test "schema file is embedded" {
    try std.testing.expect(std.mem.indexOf(u8, schema_json, "fits-registry-v1") != null);
}
