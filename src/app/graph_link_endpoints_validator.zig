//! Validator: every [`.registered_link`] edge must reference existing graph nodes (`from_id` / `to_id`).

const std = @import("std");
const validation = @import("../domain/validation.zig");

/// Ensures link edge endpoints appear in the built graph snapshot node list.
pub const GraphLinkEndpointsValidator = struct {
    /// Wraps this value as a [`validation.Validator`].
    ///
    /// Parameters:
    /// - `self`: State for the validator (unused; reserved).
    ///
    /// Returns: type-erased validator invoking [`validateAdapter`].
    pub fn asInterface(self: *GraphLinkEndpointsValidator) validation.Validator {
        return .{
            .context = self,
            .vtable = &.{
                .name = nameAdapter,
                .validate = validateAdapter,
            },
        };
    }

    fn nameAdapter(context: *anyopaque) []const u8 {
        _ = context;
        return "graph.link_endpoints";
    }

    fn validateAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: validation.ValidationInput,
    ) anyerror!validation.ValidationResult {
        _ = context;

        var list: std.ArrayList(validation.ValidationIssue) = .empty;
        defer list.deinit(allocator);

        const gv = input.graph_view orelse {
            const owned = try list.toOwnedSlice(allocator);
            return .{ .validator_name = "graph.link_endpoints", .issues = owned };
        };

        var nodes = std.StringHashMap(void).init(allocator);
        defer nodes.deinit();

        for (gv.nodes) |n| {
            try nodes.put(n.id, {});
        }

        for (gv.edges) |e| {
            if (e.kind != .registered_link) continue;
            if (!nodes.contains(e.from_id)) {
                try list.append(allocator, .{
                    .severity = .err,
                    .code = "links.missing_from",
                    .message = "registered link references an object id not present in the loaded object graph (from/out)",
                });
            }
            if (!nodes.contains(e.to_id)) {
                try list.append(allocator, .{
                    .severity = .err,
                    .code = "links.missing_to",
                    .message = "registered link references an object id not present in the loaded object graph (to/in)",
                });
            }
        }

        const owned = try list.toOwnedSlice(allocator);
        return .{ .validator_name = "graph.link_endpoints", .issues = owned };
    }
};
