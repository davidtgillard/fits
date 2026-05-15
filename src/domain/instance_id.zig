//! Canonical object instance id parsing (`{OBJ_PREFIX}-{n}`) for CLI commands.

const std = @import("std");

/// Parsed canonical object name from argv.
pub const ParsedObjName = struct {
    obj_prefix: []const u8,
    n: u64,
};

/// Parsed canonical `LINK_TYPE-n` name (mirrors [`ParsedObjName`] field pattern).
pub const ParsedLinkName = struct {
    link_type: []const u8,
    n: u64,
};

/// Wraps either an object id or a link instance id for [`fits rm`] disambiguation.
pub const RmTarget = union(enum) {
    obj: ParsedObjName,
    link: ParsedLinkName,
};

/// Parses argv for `fits rm`, trying object prefixes before link types.
pub fn parseRmTarget(name: []const u8, obj_prefixes: []const []const u8, link_types: []const []const u8) ?RmTarget {
    if (parseObjName(name, obj_prefixes)) |o| return .{ .obj = o };
    if (parseLinkName(name, link_types)) |l| return .{ .link = l };
    return null;
}

/// Parses `link_name` as `{LINK_TYPE}-{n}` using registered link type names (longest match first).
pub fn parseLinkName(link_name: []const u8, link_types: []const []const u8) ?ParsedLinkName {
    const p = parseObjName(link_name, link_types) orelse return null;
    return .{ .link_type = p.obj_prefix, .n = p.n };
}

/// Parses `full_id` as `{prefix}-{n}` using the same suffix rules as [`parseObjName`] (digits only, exact prefix match).
///
/// Parameters:
/// - `full_id`: Candidate id such as `implements-3`.
/// - `prefix`: Expected prefix before `-`, such as `implements`.
///
/// Returns: numeric suffix `n`, or `null` when the shape does not match.
pub fn parseSuffixAfterPrefix(full_id: []const u8, prefix: []const u8) ?u64 {
    return parseCanonicalSuffix(prefix, full_id);
}

/// Parses `obj_name` as `{OBJ_PREFIX}-{n}` using registered prefixes (longest match first).
///
/// Parameters:
/// - `obj_name`: Canonical id from argv (e.g. `REQ-3`); no title suffix allowed.
/// - `obj_prefixes`: Registered prefix strings (must outlive the call).
///
/// Returns: [`ParsedObjName`] on success, or `null` if no prefix matches or digits are invalid.
pub fn parseObjName(obj_name: []const u8, obj_prefixes: []const []const u8) ?ParsedObjName {
    if (obj_prefixes.len == 0 or obj_name.len == 0) return null;

    var order = std.ArrayListUnmanaged(usize).empty;
    defer order.deinit(std.heap.page_allocator);

    for (0..obj_prefixes.len) |i| {
        order.append(std.heap.page_allocator, i) catch return null;
    }

    std.mem.sortUnstable(usize, order.items, obj_prefixes, struct {
        fn less(ps: []const []const u8, a_idx: usize, b_idx: usize) bool {
            return ps[a_idx].len > ps[b_idx].len;
        }
    }.less);

    for (order.items) |idx| {
        const prefix = obj_prefixes[idx];
        if (parseCanonicalSuffix(prefix, obj_name)) |n| {
            return .{ .obj_prefix = prefix, .n = n };
        }
    }
    return null;
}

fn parseCanonicalSuffix(obj_prefix: []const u8, obj_name: []const u8) ?u64 {
    if (obj_name.len <= obj_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, obj_name, obj_prefix)) return null;
    if (obj_name[obj_prefix.len] != '-') return null;

    var i: usize = obj_prefix.len + 1;
    var n: u64 = 0;
    var digits: usize = 0;
    while (i < obj_name.len and std.ascii.isDigit(obj_name[i])) : (i += 1) {
        n *%= 10;
        n +%= obj_name[i] - '0';
        digits += 1;
    }
    if (digits == 0 or i != obj_name.len) return null;
    return n;
}

test "parseObjName longest prefix wins" {
    const prefixes = [_][]const u8{ "R", "REQ" };
    const p = parseObjName("REQ-3", &prefixes);
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("REQ", p.?.obj_prefix);
    try std.testing.expectEqual(@as(u64, 3), p.?.n);
}

test "parseObjName rejects title suffix" {
    const prefixes = [_][]const u8{"REQ"};
    try std.testing.expect(parseObjName("REQ-3 Login", &prefixes) == null);
}
