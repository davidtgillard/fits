//! C ABI status codes and last-error storage for libfits exports.

const std = @import("std");
const c_alloc = @import("c_alloc.zig");

pub const c_allocator = std.heap.c_allocator;

/// Matches negative codes in `fits_core.h`.
pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = -1,
    repo_not_found = -2,
    @"registry" = -3,
    links_invalid = -4,
    snapshot_mismatch = -5,
    unknown_id_prefix = -6,
    already_initialized = -7,
    out_of_memory = -8,
    io = -9,
    not_implemented = -10,
    internal = -11,

    pub fn toInt(self: Status) i32 {
        return @intFromEnum(self);
    }
};

threadlocal var last_error_ptr: ?[*:0]u8 = null;

/// Clears and sets the thread-local last error message (allocated on `c_allocator`).
pub fn setLastError(message: []const u8) void {
    clearLastError();
    last_error_ptr = c_alloc.allocCString(message) catch {
        last_error_ptr = null;
        return;
    };
}

pub fn setLastErrorFmt(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(c_allocator, fmt, args) catch {
        setLastError("out of memory");
        return;
    };
    defer c_allocator.free(msg);
    setLastError(msg);
}

pub fn clearLastError() void {
    c_alloc.freeCString(last_error_ptr);
    last_error_ptr = null;
}

pub fn lastErrorPtr() ?[*:0]const u8 {
    return last_error_ptr;
}

pub fn mapError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidArgument => .invalid_argument,
        error.AlreadyInitialized => .already_initialized,
        error.LinksInvalid => .links_invalid,
        error.RegistrySnapshotMismatch => .snapshot_mismatch,
        error.PersonaSnapshotMismatch => .snapshot_mismatch,
        error.UnknownIdPrefix, error.UnknownObjPrefix => .unknown_id_prefix,
        error.PersonaSnapshotNotFound, error.FileNotFound => .repo_not_found,
        error.PersonaSnapshotInvalid => .@"registry",
        else => .internal,
    };
}

pub fn statusMessage(status: Status) []const u8 {
    return switch (status) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .repo_not_found => "repository or snapshot not found",
        .@"registry" => "registry error",
        .links_invalid => "links file invalid",
        .snapshot_mismatch => "registry snapshot mismatch",
        .unknown_id_prefix => "unknown id prefix",
        .already_initialized => "repository already initialized",
        .out_of_memory => "out of memory",
        .io => "I/O error",
        .not_implemented => "not implemented",
        .internal => "internal error",
    };
}
