//! Application orchestration: wires graph building, validation, and reporting.

const std = @import("std");
const graph = @import("../domain/graph.zig");
const graph_builder = @import("../domain/graph_builder.zig");
const validation = @import("../domain/validation.zig");
const report = @import("../output/report.zig");
const cache = @import("../adapters/cache/latticedb_cache.zig");

/// Runs validation over prepared bundles using a graph builder and validator set.
pub const ValidateUseCase = struct {
    /// Allocator for graph and finding aggregation.
    allocator: std.mem.Allocator,
    /// Produces the graph snapshot passed into validators.
    graph_builder: graph_builder.GraphBuilder,
    /// Validators to run per bundle.
    validator_registry: validation.ValidatorRegistry,
    /// Optional cache (e.g. LatticeDB); integration point for future incremental runs.
    cache_store: cache.CacheStore,

    /// Builds the graph, runs every validator on every bundle, returns an owned report.
    ///
    /// Parameters:
    /// - `self`: Use-case configuration (allocator, graph builder, registry, cache stub).
    /// - `bundles`: Object bundles to validate; each is validated with the same built graph snapshot.
    ///
    /// Returns: a [`report.Report`] whose `findings` slice is owned by the caller and must be freed with `self.allocator`.
    /// On failure: allocator errors, graph build errors, or any validator error.
    pub fn execute(self: ValidateUseCase, bundles: []const graph.ObjectBundle) !report.Report {
        var snapshot = try self.graph_builder.build(self.allocator, bundles);
        defer snapshot.deinit(self.allocator);

        const validators = self.validator_registry.list();
        var findings: std.ArrayList(validation.Finding) = .empty;
        defer findings.deinit(self.allocator);

        for (bundles) |bundle| {
            const input = validation.ValidationInput{
                .bundle = bundle,
                .graph_view = &snapshot,
            };
            for (validators) |validator| {
                const result = try validator.validate(self.allocator, input);
                defer self.allocator.free(result.findings);
                try findings.appendSlice(self.allocator, result.findings);
            }
        }

        // Reserved for cache read/write once keys and invalidation are defined.
        _ = self.cache_store;

        const owned_findings = try findings.toOwnedSlice(self.allocator);
        return .{
            .findings = owned_findings,
            .summary = report.summarize(owned_findings),
        };
    }
};

/// Fixed slice of validators exposed as a [`ValidatorRegistry`].
pub const StaticValidatorRegistry = struct {
    /// Validators in run order.
    validators: []const validation.Validator,

    /// Wraps this registry for the use-case.
    ///
    /// Parameters:
    /// - `self`: Must outlive any use of the returned [`validation.ValidatorRegistry`].
    ///
    /// Returns: a type-erased [`validation.ValidatorRegistry`] backed by this struct.
    pub fn asInterface(self: *StaticValidatorRegistry) validation.ValidatorRegistry {
        return .{
            .context = self,
            .vtable = &.{
                .list = listAdapter,
            },
        };
    }

    // Returns the static `validators` slice from registry state.
    fn listAdapter(context: *anyopaque) []const validation.Validator {
        const self: *StaticValidatorRegistry = @ptrCast(@alignCast(context));
        return self.validators;
    }
};
