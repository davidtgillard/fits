//! C exports for [`libfits.h`](../include/libfits.h) (JSON over C).

const std = @import("std");
const c_errors = @import("c_errors.zig");
const c_alloc = @import("c_alloc.zig");
const repo_mod = @import("repo.zig");
const report_mod = @import("../output/report.zig");
const validation = @import("../domain/validation.zig");
const init_repo_mod = @import("../app/init_repo.zig");
const register_mod = @import("../app/register.zig");

const c_allocator = c_errors.c_allocator;
const Status = c_errors.Status;
const FitsRepo = repo_mod.FitsRepo;
const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

fn valueToCString(val: JsonValue) ![*:0]u8 {
    const text = try std.json.Stringify.valueAlloc(c_allocator, val, .{});
    defer c_allocator.free(text);
    return c_alloc.allocCString(text);
}

fn writeErrorJson(code: []const u8, message: []const u8) ![*:0]u8 {
    var o: ObjectMap = .empty;
    try o.put(c_allocator, "ok", .{ .bool = false });
    var err_o: ObjectMap = .empty;
    try err_o.put(c_allocator, "code", .{ .string = code });
    try err_o.put(c_allocator, "message", .{ .string = message });
    try o.put(c_allocator, "error", .{ .object = err_o });
    return valueToCString(.{ .object = o });
}

fn writeOkOnlyJson() ![*:0]u8 {
    var o: ObjectMap = .empty;
    try o.put(c_allocator, "ok", .{ .bool = true });
    return valueToCString(.{ .object = o });
}

fn severityTag(s: validation.FindingSeverity) []const u8 {
    return switch (s) {
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

fn writeValidateSuccessJson(rep: report_mod.Report) ![*:0]u8 {
    var root: ObjectMap = .empty;
    try root.put(c_allocator, "ok", .{ .bool = true });
    try root.put(c_allocator, "protocol_version", .{ .integer = 1 });

    var findings_a = std.json.Array.init(c_allocator);
    for (rep.findings) |f| {
        var fo: ObjectMap = .empty;
        try fo.put(c_allocator, "severity", .{ .string = severityTag(f.severity) });
        try fo.put(c_allocator, "code", .{ .string = f.code });
        try fo.put(c_allocator, "message", .{ .string = f.message });
        if (f.object_id) |oid| try fo.put(c_allocator, "object_id", .{ .string = oid });
        try findings_a.append(.{ .object = fo });
    }
    try root.put(c_allocator, "findings", .{ .array = findings_a });

    var summary: ObjectMap = .empty;
    try summary.put(c_allocator, "total_findings", .{ .integer = @intCast(rep.summary.total_findings) });
    try summary.put(c_allocator, "info_count", .{ .integer = @intCast(rep.summary.info_count) });
    try summary.put(c_allocator, "warning_count", .{ .integer = @intCast(rep.summary.warning_count) });
    try summary.put(c_allocator, "error_count", .{ .integer = @intCast(rep.summary.error_count) });
    try root.put(c_allocator, "summary", .{ .object = summary });

    return valueToCString(.{ .object = root });
}

fn mapErrToJson(err: anyerror) ![*:0]u8 {
    const status = c_errors.mapError(err);
    return writeErrorJson(@errorName(err), c_errors.statusMessage(status));
}

const ValidateRequest = struct {
    protocol_version: ?u32 = null,
    include_link_endpoints: ?bool = null,
};

export fn libfits_validate_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse {
        c_errors.setLastError("null response_json");
        return Status.invalid_argument.toInt();
    };
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else "{}";

    const parsed = std.json.parseFromSlice(ValidateRequest, c_allocator, req_str, .{
        .ignore_unknown_fields = true,
    }) catch {
        out.* = writeErrorJson("invalid_json", "request JSON parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    const include = parsed.value.include_link_endpoints orelse true;
    const rep = r.validate(.{ .include_link_endpoints = include }) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    defer {
        for (rep.findings) |f| r.allocator.free(f.message);
        r.allocator.free(rep.findings);
    }

    out.* = writeValidateSuccessJson(rep) catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const InitRequest = struct {
    no_interactive: ?bool = null,
    init_git: ?bool = null,
    edit_gitignore: ?bool = null,
};

export fn libfits_init_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else "{}";
    const parsed = std.json.parseFromSlice(InitRequest, c_allocator, req_str, .{ .ignore_unknown_fields = true }) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    const opts: init_repo_mod.InitOptions = .{
        .no_interactive = parsed.value.no_interactive orelse true,
        .init_git = parsed.value.init_git,
        .edit_gitignore = parsed.value.edit_gitignore,
    };
    r.initRepo(opts) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    out.* = writeOkOnlyJson() catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const NewNodeRequest = struct {
    id_prefix: []const u8,
    markdown: ?bool = null,
    title: ?[]const u8 = null,
};

export fn libfits_new_node_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else return Status.invalid_argument.toInt();
    const parsed = std.json.parseFromSlice(NewNodeRequest, c_allocator, req_str, .{}) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    var title_words: [1][]const u8 = .{""};
    var words = @as([]const []const u8, &.{});
    if (parsed.value.title) |t| {
        if (t.len > 0) {
            title_words[0] = t;
            words = &title_words;
        }
    }

    const id = r.newNode(parsed.value.id_prefix, .{
        .markdown = parsed.value.markdown orelse false,
        .title_words = words,
    }) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    defer r.allocator.free(id);

    var o: ObjectMap = .empty;
    o.put(c_allocator, "ok", .{ .bool = true }) catch return Status.out_of_memory.toInt();
    o.put(c_allocator, "node_id", .{ .string = id }) catch return Status.out_of_memory.toInt();
    out.* = valueToCString(.{ .object = o }) catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const NewLinkRequest = struct {
    link_type: []const u8,
    in_id: []const u8,
    out_id: []const u8,
};

export fn libfits_new_link_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else return Status.invalid_argument.toInt();
    const parsed = std.json.parseFromSlice(NewLinkRequest, c_allocator, req_str, .{}) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    r.newLink(parsed.value.link_type, parsed.value.in_id, parsed.value.out_id) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    out.* = writeOkOnlyJson() catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const RemoveRequest = struct {
    object_id: []const u8,
};

export fn libfits_remove_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else return Status.invalid_argument.toInt();
    const parsed = std.json.parseFromSlice(RemoveRequest, c_allocator, req_str, .{}) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    r.remove(parsed.value.object_id) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    out.* = writeOkOnlyJson() catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const RegisterNodeTypeRequest = struct {
    type_name: []const u8,
    abstract: ?bool = null,
    extends: ?[]const u8 = null,
    create_folder: ?bool = null,
};

export fn libfits_register_node_type_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else return Status.invalid_argument.toInt();
    const parsed = std.json.parseFromSlice(RegisterNodeTypeRequest, c_allocator, req_str, .{}) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    const reg_opts: register_mod.NodeTypeOpts = .{
        .abstract = parsed.value.abstract orelse false,
        .extends = parsed.value.extends,
        .create_folder = parsed.value.create_folder orelse false,
    };
    r.registerNodeType(parsed.value.type_name, reg_opts) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    out.* = writeOkOnlyJson() catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const RegisterLinkTypeRequest = struct {
    link_type: []const u8,
    in_type: []const u8,
    out_type: []const u8,
    create_folder: ?bool = null,
};

export fn libfits_register_link_type_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else return Status.invalid_argument.toInt();
    const parsed = std.json.parseFromSlice(RegisterLinkTypeRequest, c_allocator, req_str, .{}) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    r.registerLinkType(
        parsed.value.link_type,
        parsed.value.in_type,
        parsed.value.out_type,
        parsed.value.create_folder orelse false,
    ) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    out.* = writeOkOnlyJson() catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}

const OutputGraphRequest = struct {
    pretty_print: ?bool = null,
};

export fn libfits_output_graph_json(
    repo: ?*FitsRepo,
    request_json: ?[*:0]const u8,
    response_json: ?*?[*:0]u8,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const out = response_json orelse return Status.invalid_argument.toInt();
    const r = repo orelse {
        out.* = writeErrorJson("null_repo", "null repo") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    const req_str = if (request_json) |p| std.mem.span(p) else "{}";
    const parsed = std.json.parseFromSlice(OutputGraphRequest, c_allocator, req_str, .{
        .ignore_unknown_fields = true,
    }) catch {
        out.* = writeErrorJson("invalid_json", "parse failed") catch return Status.out_of_memory.toInt();
        return Status.invalid_argument.toInt();
    };
    defer parsed.deinit();

    const graph = r.outputGraphJson(parsed.value.pretty_print orelse false) catch |err| {
        out.* = mapErrToJson(err) catch return Status.out_of_memory.toInt();
        return c_errors.mapError(err).toInt();
    };
    defer r.allocator.free(graph);

    var parsed_graph = std.json.parseFromSlice(std.json.Value, c_allocator, graph, .{
        .allocate = .alloc_always,
    }) catch {
        out.* = writeErrorJson("internal", "graph json invalid") catch return Status.out_of_memory.toInt();
        return Status.internal.toInt();
    };
    defer parsed_graph.deinit();

    var root: ObjectMap = .empty;
    root.put(c_allocator, "ok", .{ .bool = true }) catch return Status.out_of_memory.toInt();
    root.put(c_allocator, "graph", parsed_graph.value) catch return Status.out_of_memory.toInt();
    out.* = valueToCString(.{ .object = root }) catch return Status.out_of_memory.toInt();
    return Status.ok.toInt();
}
