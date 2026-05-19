//! C exports for JSON Schema documents referenced by [`libfits.h`](../../include/libfits.h).
//!
//! Schema bytes are embedded from `src/schemas/abi/` (copies of canonical `schemas/abi/`).

const std = @import("std");

export fn FITS_validate_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/validate_request.schema.json");
}
export fn FITS_validate_response_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/validate_response.schema.json");
}
export fn FITS_output_graph_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/output_graph_request.schema.json");
}
export fn FITS_new_node_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/new_node_request.schema.json");
}
export fn FITS_new_node_response_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/new_node_response.schema.json");
}
export fn FITS_new_link_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/new_link_request.schema.json");
}
export fn FITS_remove_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/remove_request.schema.json");
}
export fn FITS_init_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/init_request.schema.json");
}
export fn FITS_register_node_type_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/register_node_type_request.schema.json");
}
export fn FITS_register_link_type_request_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/register_link_type_request.schema.json");
}
export fn FITS_error_response_schema() callconv(.c) [*:0]const u8 {
    return @embedFile("../schemas/abi/error_response.schema.json");
}

test "embedded ABI schemas are non-empty JSON objects" {
    const all = .{
        FITS_validate_request_schema(),
        FITS_validate_response_schema(),
        FITS_output_graph_request_schema(),
        FITS_new_node_request_schema(),
        FITS_new_node_response_schema(),
        FITS_new_link_request_schema(),
        FITS_remove_request_schema(),
        FITS_init_request_schema(),
        FITS_register_node_type_request_schema(),
        FITS_register_link_type_request_schema(),
        FITS_error_response_schema(),
    };
    inline for (all) |ptr| {
        const text = std.mem.span(ptr);
        try std.testing.expect(text.len > 0);
        try std.testing.expect(text[0] == '{');
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}
