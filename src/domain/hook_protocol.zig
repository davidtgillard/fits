//! JSON hook protocol types and mapping hook output to [`validation.Finding`](validation.zig).
//! Hooks are subprocesses: stdin request JSON, stdout response JSON; no I/O inside the hook.

const std = @import("std");
const validation = @import("validation.zig");

/// Current hook request/response protocol version. Bump when JSON shape changes.
pub const protocol_version: u32 = 1;

/// Field reserved in schemas/docs for a future full-graph query API (hooks call the same model).
pub const extension_graph_api_placeholder = "future: in-process or stdio RPC over graph_access API";

pub const FileEncoding = enum {
    utf8,
    base64,

    pub fn jsonTag(tag: *const FileEncoding) []const u8 {
        return switch (tag.*) {
            .utf8 => "utf-8",
            .base64 => "base64",
        };
    }
};

/// One file inside an object or link folder for hook payloads.
pub const HookFileEntry = struct {
    relative_path: []const u8,
    encoding: FileEncoding,
    /// UTF-8 text or base64 payload per `encoding`.
    content: []const u8,
};

/// One object in the hook `work` batch.
pub const HookWorkObject = struct {
    id: []const u8,
    files: []const HookFileEntry,
};

/// One link instance in the hook `work` batch.
pub const HookWorkLink = struct {
    id: []const u8,
    link_type: []const u8,
    out: []const u8,
    in: []const u8,
    labels: ?[][]const u8 = null,
    folder_files: []const HookFileEntry = &.{},
};

pub const HookRunMeta = struct {
    /// Opaque id for logs (e.g. timestamp-based).
    run_id: []const u8,
    /// Git `HEAD` when available.
    git_head: ?[]const u8 = null,
    /// How validation was triggered.
    trigger: []const u8,
};

/// Graph node as sent to hooks.
pub const HookGraphNodeJson = struct {
    id: []const u8,
};

/// Edge as sent to hooks (`kind`: `registered_link` \| `references`).
pub const HookGraphEdgeJson = struct {
    from_id: []const u8,
    to_id: []const u8,
    kind: []const u8,
    link_type: []const u8,
};

/// Allocates a single finding for hook I/O or protocol errors.
///
/// Parameters:
/// - `allocator`: Owns duplicated `message` in the returned finding.
/// - `hook_name`: Short hook label for the prefix.
/// - `detail`: Problem description (stderr tail, parse error, etc.).
///
/// Returns: a single-element slice the caller must free (each finding’s `message` with `allocator.free`).
pub fn findingsFromHookIoFailure(
    allocator: std.mem.Allocator,
    hook_name: []const u8,
    detail: []const u8,
) ![]validation.Finding {
    const msg = try std.fmt.allocPrint(allocator, "hook {s}: {s}", .{ hook_name, detail });
    errdefer allocator.free(msg);
    const out = try allocator.alloc(validation.Finding, 1);
    out[0] = .{
        .severity = .err,
        .code = "hook.io",
        .message = msg,
        .object_id = null,
    };
    return out;
}

fn freeFindingMessages(allocator: std.mem.Allocator, findings: []validation.Finding) void {
    for (findings) |f| allocator.free(f.message);
}

/// Parses hook stdout JSON and appends [`validation.Finding`] for each invalid item or protocol mismatch.
///
/// Parameters:
/// - `allocator`: Allocates appended findings and duplicated strings.
/// - `response_body`: Raw UTF-8 JSON from the hook stdout.
/// - `hook_name`: Label used in diagnostic messages.
/// - `findings`: Receives appended items on success.
///
/// Returns: nothing on success. Malformed JSON or version mismatch only append diagnostic findings (no error return); allocation failure propagates.
pub fn appendFindingsFromHookResponseJson(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    hook_name: []const u8,
    findings: *std.ArrayListUnmanaged(validation.Finding),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{ .allocate = .alloc_always }) catch |err| {
        const detail = try std.fmt.allocPrint(allocator, "parse error: {any}", .{err});
        defer allocator.free(detail);
        const batch = try findingsFromHookIoFailure(allocator, hook_name, detail);
        defer freeFindingMessages(allocator, batch);
        defer allocator.free(batch);
        try findings.appendSlice(allocator, batch);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => {
            const batch = try findingsFromHookIoFailure(allocator, hook_name, "expected JSON object at top level");
            defer freeFindingMessages(allocator, batch);
            defer allocator.free(batch);
            try findings.appendSlice(allocator, batch);
            return;
        },
    };

    const pv = obj.get("protocol_version") orelse {
        const batch = try findingsFromHookIoFailure(allocator, hook_name, "missing protocol_version");
        defer freeFindingMessages(allocator, batch);
        defer allocator.free(batch);
        try findings.appendSlice(allocator, batch);
        return;
    };
    const ver: u32 = switch (pv) {
        .integer => |i| if (i < 0) {
            const batch = try findingsFromHookIoFailure(allocator, hook_name, "invalid protocol_version");
            defer freeFindingMessages(allocator, batch);
            defer allocator.free(batch);
            try findings.appendSlice(allocator, batch);
            return;
        } else @intCast(i),
        else => {
            const batch = try findingsFromHookIoFailure(allocator, hook_name, "invalid protocol_version type");
            defer freeFindingMessages(allocator, batch);
            defer allocator.free(batch);
            try findings.appendSlice(allocator, batch);
            return;
        },
    };
    if (ver != protocol_version) {
        const detail = try std.fmt.allocPrint(allocator, "unsupported protocol_version {d}", .{ver});
        defer allocator.free(detail);
        const batch = try findingsFromHookIoFailure(allocator, hook_name, detail);
        defer freeFindingMessages(allocator, batch);
        defer allocator.free(batch);
        try findings.appendSlice(allocator, batch);
        return;
    }

    if (obj.get("objects")) |ov| {
        try appendScopeFindings(allocator, .object, ov, "hook.object.invalid", findings);
    }
    if (obj.get("links")) |lv| {
        try appendScopeFindings(allocator, .link, lv, "hook.link.invalid", findings);
    }
}

const Scope = enum { object, link };

fn appendScopeFindings(
    allocator: std.mem.Allocator,
    scope: Scope,
    value: std.json.Value,
    code_invalid: []const u8,
    findings: *std.ArrayListUnmanaged(validation.Finding),
) !void {
    const arr = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const id_val = row.get("id") orelse continue;
        const id = switch (id_val) {
            .string => |s| s,
            else => continue,
        };
        const status_val = row.get("status") orelse continue;
        const status = switch (status_val) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, status, "ok")) continue;

        if (!std.mem.eql(u8, status, "invalid")) {
            const msg = try std.fmt.allocPrint(allocator, "hook item {s}: unknown status {s}", .{ id, status });
            errdefer allocator.free(msg);
            try findings.append(allocator, .{
                .severity = .err,
                .code = "hook.protocol",
                .message = msg,
                .object_id = null,
            });
            continue;
        }

        const errs = row.get("errors") orelse {
            const msg = switch (scope) {
                .object => try std.fmt.allocPrint(allocator, "hook object {s}: invalid but errors missing", .{id}),
                .link => try std.fmt.allocPrint(allocator, "hook link {s}: invalid but errors missing", .{id}),
            };
            errdefer allocator.free(msg);
            try findings.append(allocator, .{
                .severity = .err,
                .code = code_invalid,
                .message = msg,
                .object_id = null,
            });
            continue;
        };
        const err_arr = switch (errs) {
            .array => |e| e,
            else => {
                const msg = switch (scope) {
                    .object => try std.fmt.allocPrint(allocator, "hook object {s}: errors not an array", .{id}),
                    .link => try std.fmt.allocPrint(allocator, "hook link {s}: errors not an array", .{id}),
                };
                errdefer allocator.free(msg);
                try findings.append(allocator, .{
                    .severity = .err,
                    .code = code_invalid,
                    .message = msg,
                    .object_id = null,
                });
                continue;
            },
        };

        for (err_arr.items) |ev| {
            const er = switch (ev) {
                .object => |o| o,
                else => continue,
            };
            const code_val = er.get("code") orelse continue;
            const code = switch (code_val) {
                .string => |s| s,
                else => "hook.error",
            };
            const msg_val = er.get("message") orelse continue;
            const base = switch (msg_val) {
                .string => |s| s,
                else => "(no message)",
            };
            const msg = switch (scope) {
                .object => try std.fmt.allocPrint(allocator, "{s} [{s}]: {s}", .{ id, code, base }),
                .link => try std.fmt.allocPrint(allocator, "link {s} [{s}]: {s}", .{ id, code, base }),
            };
            errdefer allocator.free(msg);
            try findings.append(allocator, .{
                .severity = .err,
                .code = code_invalid,
                .message = msg,
                .object_id = null,
            });
        }
    }
}

test "hook response invalid object" {
    const alloc = std.testing.allocator;
    const body =
        \\{"protocol_version":1,"objects":[{"id":"O1","status":"invalid","errors":[{"code":"x","message":"bad"}]}]}
    ;
    var findings: std.ArrayListUnmanaged(validation.Finding) = .empty;
    defer {
        for (findings.items) |f| alloc.free(f.message);
        findings.deinit(alloc);
    }
    try appendFindingsFromHookResponseJson(alloc, body, "testhook", &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings("hook.object.invalid", findings.items[0].code);
}
