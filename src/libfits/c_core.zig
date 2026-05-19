//! C exports for [`fits_core.h`](../include/fits_core.h.in) (generated at build time).

const std = @import("std");
const build_options = @import("build_options");
const c_errors = @import("c_errors.zig");
const c_alloc = @import("c_alloc.zig");
const repo_mod = @import("repo.zig");
const report_mod = @import("../output/report.zig");
const validation = @import("../domain/validation.zig");
const init_repo_mod = @import("../app/init_repo.zig");
const register_mod = @import("../app/register.zig");
const new_node_mod = @import("../app/new_node.zig");

const c_allocator = c_errors.c_allocator;
const Status = c_errors.Status;

const FitsRepo = repo_mod.FitsRepo;

export fn FITS_api_version() callconv(.c) u32 {
    return build_options.fits_api_version_packed;
}

export fn FITS_version_string() callconv(.c) [*:0]const u8 {
    return build_options.fits_version[0.. :0].ptr;
}

export fn FITS_free(ptr: ?*anyopaque) callconv(.c) void {
    c_alloc.freeCString(@ptrCast(ptr));
}

export fn FITS_last_error() callconv(.c) [*:0]const u8 {
    return c_errors.lastErrorPtr() orelse "";
}

const CRepoOpenOptions = extern struct {
    struct_size: u32,
    repo_root: ?[*:0]const u8,
    registry_snapshot_path: ?[*:0]const u8,
};

const CValidateOptions = extern struct {
    struct_size: u32,
    include_link_endpoints: i32,
};

const CNewNodeOptions = extern struct {
    struct_size: u32,
    id_prefix: ?[*:0]const u8,
    markdown: i32,
    title: ?[*:0]const u8,
};

const CNewLinkOptions = extern struct {
    struct_size: u32,
    link_type: ?[*:0]const u8,
    in_id: ?[*:0]const u8,
    out_id: ?[*:0]const u8,
};

const CRegisterNodeTypeOptions = extern struct {
    struct_size: u32,
    type_name: ?[*:0]const u8,
    abstract: i32,
    extends: ?[*:0]const u8,
    create_folder: i32,
};

const CRegisterLinkTypeOptions = extern struct {
    struct_size: u32,
    link_type: ?[*:0]const u8,
    in_type: ?[*:0]const u8,
    out_type: ?[*:0]const u8,
    create_folder: i32,
};

const CRepoInitOptions = extern struct {
    struct_size: u32,
    no_interactive: i32,
    init_git: i32,
    edit_gitignore: i32,
};

const CFitsFinding = extern struct {
    struct_size: u32,
    severity: i32,
    code: ?[*:0]const u8,
    message: ?[*:0]const u8,
    object_id: ?[*:0]const u8,
};

const CFitsValidateSummary = extern struct {
    struct_size: u32,
    total_findings: usize,
    info_count: usize,
    warning_count: usize,
    error_count: usize,
};

const CFitsValidateResult = extern struct {
    struct_size: u32,
    findings: ?[*]CFitsFinding,
    findings_len: usize,
    summary: CFitsValidateSummary,
};

var g_io: std.Io.Threaded = std.Io.Threaded.init_single_threaded;

fn defaultIo() std.Io {
    return g_io.io();
}

fn severityToC(s: validation.FindingSeverity) i32 {
    return switch (s) {
        .info => 0,
        .warn => 1,
        .err => 2,
    };
}

fn fail(status: Status, comptime fmt: []const u8, args: anytype) Status {
    c_errors.setLastErrorFmt(fmt, args);
    return status;
}

fn failStatus(status: Status) Status {
    c_errors.setLastError(c_errors.statusMessage(status));
    return status;
}

export fn FITS_CORE_repo_open(options: ?*const CRepoOpenOptions) callconv(.c) ?*FitsRepo {
    c_errors.clearLastError();
    const opts = options orelse {
        _ = fail(.invalid_argument, "null options", .{});
        return null;
    };
    if (opts.struct_size != @sizeOf(CRepoOpenOptions)) {
        _ = fail(.invalid_argument, "invalid FitsRepoOpenOptions struct_size", .{});
        return null;
    }
    const root = if (opts.repo_root) |p| std.mem.span(p) else ".";
    const snap: ?[]const u8 = if (opts.registry_snapshot_path) |p| std.mem.span(p) else null;

    const io = defaultIo();
    const repo = repo_mod.FitsRepo.open(c_allocator, io, .{
        .repo_root = root,
        .registry_snapshot_path = snap,
    }) catch |err| {
        _ = fail(c_errors.mapError(err), "FITS_CORE_repo_open: {s}", .{@errorName(err)});
        return null;
    };
    return repo;
}

export fn FITS_CORE_repo_close(repo: ?*FitsRepo) callconv(.c) void {
    if (repo) |r| r.close();
}

export fn FITS_CORE_repo_init(repo: ?*FitsRepo, options: ?*const CRepoInitOptions) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const opts = options orelse return fail(.invalid_argument, "null options", .{}).toInt();
    if (opts.struct_size != @sizeOf(CRepoInitOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();

    const init_opts: init_repo_mod.InitOptions = .{
        .no_interactive = opts.no_interactive != 0,
        .init_git = if (opts.init_git != 0) true else null,
        .edit_gitignore = if (opts.edit_gitignore != 0) true else null,
    };
    r.initRepo(init_opts) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_registry_register_node_type(repo: ?*FitsRepo, options: ?*const CRegisterNodeTypeOptions) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const opts = options orelse return fail(.invalid_argument, "null options", .{}).toInt();
    if (opts.struct_size != @sizeOf(CRegisterNodeTypeOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();
    const type_name = if (opts.type_name) |p| std.mem.span(p) else return fail(.invalid_argument, "type_name required", .{}).toInt();
    if (opts.abstract == 0 and opts.extends == null) return fail(.invalid_argument, "extends required for concrete type", .{}).toInt();

    const reg_opts: register_mod.NodeTypeOpts = .{
        .abstract = opts.abstract != 0,
        .extends = if (opts.extends) |p| std.mem.span(p) else null,
        .create_folder = opts.create_folder != 0,
    };
    r.registerNodeType(type_name, reg_opts) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_registry_register_link_type(repo: ?*FitsRepo, options: ?*const CRegisterLinkTypeOptions) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const opts = options orelse return fail(.invalid_argument, "null options", .{}).toInt();
    if (opts.struct_size != @sizeOf(CRegisterLinkTypeOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();
    const link_type = if (opts.link_type) |p| std.mem.span(p) else return fail(.invalid_argument, "link_type required", .{}).toInt();
    const in_type = if (opts.in_type) |p| std.mem.span(p) else return fail(.invalid_argument, "in_type required", .{}).toInt();
    const out_type = if (opts.out_type) |p| std.mem.span(p) else return fail(.invalid_argument, "out_type required", .{}).toInt();

    r.registerLinkType(link_type, in_type, out_type, opts.create_folder != 0) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_registry_verify_snapshot(repo: ?*FitsRepo) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    r.verifyRegistrySnapshot() catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_new_node(repo: ?*FitsRepo, options: ?*const CNewNodeOptions, out_node_id: ?*?[*:0]u8) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const out = out_node_id orelse return fail(.invalid_argument, "null out_node_id", .{}).toInt();
    const opts = options orelse return fail(.invalid_argument, "null options", .{}).toInt();
    if (opts.struct_size != @sizeOf(CNewNodeOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();
    const id_prefix = if (opts.id_prefix) |p| std.mem.span(p) else return fail(.invalid_argument, "id_prefix required", .{}).toInt();

    var title_words: [1][]const u8 = .{""};
    var words = @as([]const []const u8, &.{});
    if (opts.title) |t| {
        const title = std.mem.span(t);
        if (title.len > 0) {
            title_words[0] = title;
            words = &title_words;
        }
    }

    const id = r.newNode(id_prefix, .{
        .markdown = opts.markdown != 0,
        .title_words = words,
    }) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();

    const c_id = c_alloc.allocCString(id) catch |err| {
        r.allocator.free(id);
        return fail(c_errors.mapError(err), "out of memory", .{}).toInt();
    };
    r.allocator.free(id);
    out.* = c_id;
    return Status.ok.toInt();
}

export fn FITS_CORE_new_link(repo: ?*FitsRepo, options: ?*const CNewLinkOptions) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const opts = options orelse return fail(.invalid_argument, "null options", .{}).toInt();
    if (opts.struct_size != @sizeOf(CNewLinkOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();
    const link_type = if (opts.link_type) |p| std.mem.span(p) else return fail(.invalid_argument, "link_type required", .{}).toInt();
    const in_id = if (opts.in_id) |p| std.mem.span(p) else return fail(.invalid_argument, "in_id required", .{}).toInt();
    const out_id = if (opts.out_id) |p| std.mem.span(p) else return fail(.invalid_argument, "out_id required", .{}).toInt();

    r.newLink(link_type, in_id, out_id) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_remove_obj(repo: ?*FitsRepo, object_id: ?[*:0]const u8) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const id = if (object_id) |p| std.mem.span(p) else return fail(.invalid_argument, "object_id required", .{}).toInt();
    r.remove(id) catch |err| return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    return Status.ok.toInt();
}

export fn FITS_CORE_validate(
    repo: ?*FitsRepo,
    options: ?*const CValidateOptions,
    out_result: ?*?*CFitsValidateResult,
) callconv(.c) i32 {
    c_errors.clearLastError();
    const r = repo orelse return fail(.invalid_argument, "null repo", .{}).toInt();
    const out = out_result orelse return fail(.invalid_argument, "null out_result", .{}).toInt();
    const include_link: bool = blk: {
        if (options) |opts| {
            if (opts.struct_size != @sizeOf(CValidateOptions)) return fail(.invalid_argument, "invalid struct_size", .{}).toInt();
            break :blk opts.include_link_endpoints != 0;
        }
        break :blk true;
    };

    const rep = r.validate(.{ .include_link_endpoints = include_link }) catch |err| {
        return fail(c_errors.mapError(err), "{s}", .{@errorName(err)}).toInt();
    };
    defer freeReportFindings(r.allocator, rep);

    const c_result = c_allocator.create(CFitsValidateResult) catch return failStatus(.out_of_memory).toInt();
    errdefer c_allocator.destroy(c_result);

    const findings = c_allocator.alloc(CFitsFinding, rep.findings.len) catch {
        c_allocator.destroy(c_result);
        return failStatus(.out_of_memory).toInt();
    };
    errdefer c_allocator.free(findings);

    for (rep.findings, 0..) |f, i| {
        const code = c_alloc.allocCString(f.code) catch {
            freeCFindingsPartial(findings, i);
            c_allocator.free(findings);
            c_allocator.destroy(c_result);
            return failStatus(.out_of_memory).toInt();
        };
        const message = c_alloc.allocCString(f.message) catch {
            c_alloc.freeCString(code);
            freeCFindingsPartial(findings, i);
            c_allocator.free(findings);
            c_allocator.destroy(c_result);
            return failStatus(.out_of_memory).toInt();
        };
        const object_id: ?[*:0]const u8 = if (f.object_id) |oid|
            c_alloc.allocCString(oid) catch {
                c_alloc.freeCString(message);
                c_alloc.freeCString(code);
                freeCFindingsPartial(findings, i);
                c_allocator.free(findings);
                c_allocator.destroy(c_result);
                return failStatus(.out_of_memory).toInt();
            }
        else
            null;

        findings[i] = .{
            .struct_size = @sizeOf(CFitsFinding),
            .severity = severityToC(f.severity),
            .code = code,
            .message = message,
            .object_id = object_id,
        };
    }

    c_result.* = .{
        .struct_size = @sizeOf(CFitsValidateResult),
        .findings = if (findings.len > 0) findings.ptr else null,
        .findings_len = findings.len,
        .summary = .{
            .struct_size = @sizeOf(CFitsValidateSummary),
            .total_findings = rep.summary.total_findings,
            .info_count = rep.summary.info_count,
            .warning_count = rep.summary.warning_count,
            .error_count = rep.summary.error_count,
        },
    };
    out.* = c_result;
    return Status.ok.toInt();
}

fn freeReportFindings(allocator: std.mem.Allocator, rep: report_mod.Report) void {
    for (rep.findings) |f| allocator.free(f.message);
    allocator.free(rep.findings);
}

fn freeCFindingsPartial(findings: []CFitsFinding, count: usize) void {
    for (findings[0..count]) |f| {
        c_alloc.freeCString(f.code);
        c_alloc.freeCString(f.message);
        c_alloc.freeCString(f.object_id);
    }
}

export fn FITS_CORE_validate_result_destroy(result: ?*CFitsValidateResult) callconv(.c) void {
    const res = result orelse return;
    if (res.findings) |base| {
        const slice = base[0..res.findings_len];
        freeCFindingsPartial(slice, slice.len);
        c_allocator.free(slice);
    }
    c_allocator.destroy(res);
}
