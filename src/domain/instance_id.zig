//! Canonical node instance id parsing (`{NODE_TYPE_PREFIX}-{n}`) for CLI commands.
//! A **graph object** is either a node or a link; this module covers node-shaped ids only.

const std = @import("std");

/// Parsed canonical node id from argv (`{prefix}-{n}`).
pub const ParsedNodeName = struct {
    /// Registered node-type prefix (matches [`fits_registry`] `obj_prefix` entries).
    node_prefix: []const u8,
    n: u64,
};

/// Parsed canonical `LINK_TYPE-n` name (mirrors [`ParsedNodeName`] field pattern).
pub const ParsedLinkName = struct {
    link_type: []const u8,
    n: u64,
};

/// Wraps either a node id or a link instance id for [`fits rm`] disambiguation.
pub const RmTarget = union(enum) {
    node: ParsedNodeName,
    link: ParsedLinkName,
};

/// Parses argv for `fits rm`, trying node-type prefixes before link types.
pub fn parseRmTarget(name: []const u8, node_prefixes: []const []const u8, link_types: []const []const u8) ?RmTarget {
    if (parseNodeName(name, node_prefixes)) |o| return .{ .node = o };
    if (parseLinkName(name, link_types)) |l| return .{ .link = l };
    return null;
}

/// Parses `link_name` as `{LINK_TYPE}-{n}` using registered link type names (longest match first).
pub fn parseLinkName(link_name: []const u8, link_types: []const []const u8) ?ParsedLinkName {
    const p = parseNodeName(link_name, link_types) orelse return null;
    return .{ .link_type = p.node_prefix, .n = p.n };
}

/// Parses `full_id` as `{prefix}-{n}` using the same suffix rules as [`parseNodeName`] (digits only, exact prefix match).
///
/// Parameters:
/// - `full_id`: Candidate id such as `implements-3`.
/// - `prefix`: Expected prefix before `-`, such as `implements`.
///
/// Returns: numeric suffix `n`, or `null` when the shape does not match.
pub fn parseSuffixAfterPrefix(full_id: []const u8, prefix: []const u8) ?u64 {
    return parseCanonicalSuffix(prefix, full_id);
}

/// Parses `node_name` as `{NODE_TYPE_PREFIX}-{n}` using registered prefixes (longest match first).
///
/// Parameters:
/// - `node_name`: Canonical id from argv (e.g. `REQ-3`); no title suffix allowed.
/// - `node_prefixes`: Registered prefix strings (must outlive the call).
///
/// Returns: [`ParsedNodeName`] on success, or `null` if no prefix matches or digits are invalid.
pub fn parseNodeName(node_name: []const u8, node_prefixes: []const []const u8) ?ParsedNodeName {
    if (node_prefixes.len == 0 or node_name.len == 0) return null;

    var order = std.ArrayListUnmanaged(usize).empty;
    defer order.deinit(std.heap.page_allocator);

    for (0..node_prefixes.len) |i| {
        order.append(std.heap.page_allocator, i) catch return null;
    }

    std.mem.sortUnstable(usize, order.items, node_prefixes, struct {
        fn less(ps: []const []const u8, a_idx: usize, b_idx: usize) bool {
            return ps[a_idx].len > ps[b_idx].len;
        }
    }.less);

    for (order.items) |idx| {
        const prefix = node_prefixes[idx];
        if (parseCanonicalSuffix(prefix, node_name)) |n| {
            return .{ .node_prefix = prefix, .n = n };
        }
    }
    return null;
}

fn parseCanonicalSuffix(node_prefix: []const u8, node_name: []const u8) ?u64 {
    if (node_name.len <= node_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, node_name, node_prefix)) return null;
    if (node_name[node_prefix.len] != '-') return null;

    var i: usize = node_prefix.len + 1;
    var n: u64 = 0;
    var digits: usize = 0;
    while (i < node_name.len and std.ascii.isDigit(node_name[i])) : (i += 1) {
        n *%= 10;
        n +%= node_name[i] - '0';
        digits += 1;
    }
    if (digits == 0 or i != node_name.len) return null;
    return n;
}

test "parseNodeName longest prefix wins" {
    const prefixes = [_][]const u8{ "R", "REQ" };
    const p = parseNodeName("REQ-3", &prefixes);
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("REQ", p.?.node_prefix);
    try std.testing.expectEqual(@as(u64, 3), p.?.n);
}

test "parseNodeName rejects title suffix" {
    const prefixes = [_][]const u8{"REQ"};
    try std.testing.expect(parseNodeName("REQ-3 Login", &prefixes) == null);
}
