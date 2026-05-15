//! Minimal JSONC preprocessing: strips line `//` and block `/* */` comments outside JSON strings.

const std = @import("std");

/// Allocates JSON text with JSONC comments removed (caller frees).
///
/// Does not strip `#` comments (not JSONC); links schema validation applies after stripping.
///
/// Parameters:
/// - `allocator`: Allocates the returned slice.
/// - `source`: UTF-8 JSONC source bytes.
///
/// Returns: owned normalized JSON bytes suitable for [`std.json`] parsing.
pub fn stripJsoncComments(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const Mode = enum { normal, line_comment, block_comment, string, escape };

    var mode: Mode = .normal;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (mode) {
            .normal => {
                if (c == '"') {
                    try out.append(allocator, '"');
                    mode = .string;
                    i += 1;
                    continue;
                }
                if (c == '/' and i + 1 < source.len) {
                    const next = source[i + 1];
                    if (next == '/') {
                        mode = .line_comment;
                        i += 2;
                        continue;
                    }
                    if (next == '*') {
                        mode = .block_comment;
                        i += 2;
                        continue;
                    }
                }
                try out.append(allocator, c);
                i += 1;
            },
            .line_comment => {
                if (c == '\n') {
                    try out.append(allocator, '\n');
                    mode = .normal;
                }
                i += 1;
            },
            .block_comment => {
                if (c == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    mode = .normal;
                    i += 2;
                } else {
                    i += 1;
                }
            },
            .string => {
                if (c == '\\') {
                    try out.append(allocator, '\\');
                    mode = .escape;
                    i += 1;
                    continue;
                }
                try out.append(allocator, c);
                if (c == '"') {
                    mode = .normal;
                }
                i += 1;
            },
            .escape => {
                try out.append(allocator, c);
                mode = .string;
                i += 1;
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

test "stripJsoncComments removes line comment" {
    const a = std.testing.allocator;
    const src =
        \\{
        \\  // hello
        \\  "a": 1
        \\}
    ;
    const out = try stripJsoncComments(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "//") == null);
}

test "stripJsoncComments preserves string slashes" {
    const a = std.testing.allocator;
    const src = "{\"x\":\"//not-a-comment\"}";
    const out = try stripJsoncComments(a, src);
    defer a.free(out);
    try std.testing.expectEqualStrings(src, out);
}
