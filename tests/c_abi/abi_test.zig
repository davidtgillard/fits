//! ABI test executable linking libfits C API (core + JSON) via explicit extern declarations.

const std = @import("std");
const build_options = @import("build_options");

const FitsRepo = opaque {};
const FitsRepoOpenOptions = extern struct {
    struct_size: u32,
    repo_root: ?[*:0]const u8,
    registry_snapshot_path: ?[*:0]const u8,
};

const fits_api_version = @extern(*const fn () callconv(.c) u32, .{ .name = "fits_api_version" });
const fits_free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "fits_free" });
const fits_repo_open = @extern(*const fn (?*const FitsRepoOpenOptions) callconv(.c) ?*FitsRepo, .{ .name = "fits_repo_open" });
const fits_repo_close = @extern(*const fn (?*FitsRepo) callconv(.c) void, .{ .name = "fits_repo_close" });
const libfits_init_json = @extern(*const fn (?*FitsRepo, ?[*:0]const u8, ?*?[*:0]u8) callconv(.c) i32, .{ .name = "libfits_init_json" });
const libfits_register_node_type_json = @extern(*const fn (?*FitsRepo, ?[*:0]const u8, ?*?[*:0]u8) callconv(.c) i32, .{ .name = "libfits_register_node_type_json" });
const libfits_validate_json = @extern(*const fn (?*FitsRepo, ?[*:0]const u8, ?*?[*:0]u8) callconv(.c) i32, .{ .name = "libfits_validate_json" });

pub fn main(init: std.process.Init) !void {
    try runAbiTest(init.gpa, init.io);
}

const TmpDir = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: [sub_path_len]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn cleanup(self: *TmpDir, io: std.Io) void {
        self.dir.close(io);
        self.parent_dir.deleteTree(io, &self.sub_path) catch {};
        self.parent_dir.close(io);
        self.* = undefined;
    }
};

fn makeTmpDir(io: std.Io) !TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    io.random(&random_bytes);
    var sub_path: [TmpDir.sub_path_len]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

    const cwd = std.Io.Dir.cwd();
    var cache_dir = try cwd.createDirPathOpen(io, ".zig-cache", .{});
    defer cache_dir.close(io);
    const parent_dir = try cache_dir.createDirPathOpen(io, "tmp", .{});
    const dir = try parent_dir.createDirPathOpen(io, &sub_path, .{});

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}

fn runAbiTest(alloc: std.mem.Allocator, io: std.Io) !void {
    if (fits_api_version() != build_options.fits_api_version_packed) return error.ApiVersionMismatch;

    var tmp = try makeTmpDir(io);
    defer tmp.cleanup(io);
    try tmp.dir.createDirPath(io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: [:0]const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const open_opts = FitsRepoOpenOptions{
        .struct_size = @sizeOf(FitsRepoOpenOptions),
        .repo_root = repo_abs.ptr,
        .registry_snapshot_path = null,
    };
    const repo = fits_repo_open(&open_opts) orelse return error.RepoOpenFailed;

    const init_req = "{}";
    var init_resp: ?[*:0]u8 = null;
    const init_st = libfits_init_json(repo, init_req.ptr, &init_resp);
    if (init_st != 0) return error.InitFailed;
    defer fits_free(init_resp);

    const reg_req =
        \\{"type_name":"req","abstract":true}
    ;
    var reg_resp: ?[*:0]u8 = null;
    const reg_st = libfits_register_node_type_json(repo, reg_req.ptr, &reg_resp);
    if (reg_st != 0) return error.RegisterFailed;
    defer fits_free(reg_resp);

    const reg2_req =
        \\{"type_name":"REQ","extends":"req"}
    ;
    var reg2_resp: ?[*:0]u8 = null;
    const reg2_st = libfits_register_node_type_json(repo, reg2_req.ptr, &reg2_resp);
    if (reg2_st != 0) return error.RegisterFailed;
    defer fits_free(reg2_resp);

    const val_req = "{\"include_link_endpoints\":true}";
    var val_resp: ?[*:0]u8 = null;
    const val_st = libfits_validate_json(repo, val_req.ptr, &val_resp);
    if (val_st != 0) return error.ValidateFailed;
    defer fits_free(val_resp);

    const body = std.mem.span(val_resp.?);
    if (std.mem.indexOf(u8, body, "\"ok\":true") == null) return error.ValidateResponseMissingOk;
    if (std.mem.indexOf(u8, body, "\"findings\"") == null) return error.ValidateResponseMissingFindings;

    fits_repo_close(repo);
}
