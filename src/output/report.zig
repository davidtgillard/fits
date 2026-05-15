//! Aggregated validation output and renderers for human or machine consumers.

const std = @import("std");
const validation = @import("../domain/validation.zig");

/// Counts of findings by severity for dashboards and exit-code policy.
pub const Summary = struct {
    /// Total number of findings.
    total_findings: usize,
    /// Count with severity [`FindingSeverity.info`](validation.FindingSeverity).
    info_count: usize,
    /// Count with severity [`FindingSeverity.warn`](validation.FindingSeverity).
    warning_count: usize,
    /// Count with severity [`FindingSeverity.err`](validation.FindingSeverity).
    error_count: usize,
};

/// Normalized report: raw findings plus precomputed summary.
pub const Report = struct {
    /// All findings from all validators in run order (concatenated).
    findings: []const validation.Finding,
    /// Aggregated counts by severity.
    summary: Summary,
};

/// Type-erased report renderer (JSON, SARIF, plain text, etc.).
pub const Renderer = struct {
    /// Renderer implementation state.
    context: *anyopaque,
    /// Virtual methods.
    vtable: *const VTable,

    /// Virtual methods for [`Renderer`].
    pub const VTable = struct {
        /// Renders `report` (e.g. to stdout, a buffer, or structured diagnostics).
        ///
        /// Parameters:
        /// - `context`: Implementation state (`Renderer.context`).
        /// - `rep`: Report to render.
        ///
        /// Returns: nothing on success, or an arbitrary error if rendering fails.
        render: *const fn (context: *anyopaque, rep: Report) anyerror!void,
    };

    /// Renders the report using the configured implementation.
    ///
    /// Parameters:
    /// - `self`: Type-erased renderer.
    /// - `rep`: Report to pass to the implementation.
    ///
    /// Returns: nothing on success, or the same error as the underlying `render` hook.
    pub fn render(self: Renderer, rep: Report) !void {
        return self.vtable.render(self.context, rep);
    }
};

/// Minimal debug-oriented renderer for early CLI output.
pub const TextRenderer = struct {
    /// Returns a [`Renderer`] backed by this value.
    ///
    /// Parameters:
    /// - `self`: Must outlive any `render` calls made on the returned [`Renderer`].
    ///
    /// Returns: a [`Renderer`] whose context pointer aliases `self`.
    pub fn asInterface(self: *TextRenderer) Renderer {
        return .{
            .context = self,
            .vtable = &.{
                .render = renderAdapter,
            },
        };
    }

    // Prints one summary line via `std.debug.print`.
    fn renderAdapter(context: *anyopaque, rep: Report) anyerror!void {
        const self: *TextRenderer = @ptrCast(@alignCast(context));
        _ = self;

        std.debug.print(
            "findings={d} info={d} warning={d} error={d}\n",
            .{ rep.summary.total_findings, rep.summary.info_count, rep.summary.warning_count, rep.summary.error_count },
        );
    }
};

/// Computes severity counts from a flat finding list.
///
/// Parameters:
/// - `findings`: Findings to aggregate (order does not matter).
///
/// Returns: a [`Summary`] with `total_findings == findings.len` and per-severity counts.
pub fn summarize(findings: []const validation.Finding) Summary {
    var summary = Summary{
        .total_findings = findings.len,
        .info_count = 0,
        .warning_count = 0,
        .error_count = 0,
    };

    for (findings) |finding| {
        switch (finding.severity) {
            .info => summary.info_count += 1,
            .warn => summary.warning_count += 1,
            .err => summary.error_count += 1,
        }
    }

    return summary;
}
