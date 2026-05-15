//! Pure validation contracts: inputs, findings, and pluggable validators.
//! Validators must not perform I/O; adapters run them on snapshots built from disk.

const std = @import("std");
const graph = @import("graph.zig");

/// Severity of a single validation finding.
pub const FindingSeverity = enum {
    /// Informational message; does not indicate failure.
    info,
    /// Non-fatal issue (named `warn` because `warning` / `error` collide with Zig builtins).
    warn,
    /// Fatal validation failure for the checked scope.
    err,
};

/// One issue reported by a validator.
pub const Finding = struct {
    /// How serious the finding is.
    severity: FindingSeverity,
    /// Short machine-oriented code (e.g. for CI or SARIF mapping later).
    code: []const u8,
    /// Human-readable explanation.
    message: []const u8,
    /// Object the finding refers to, if any.
    object_id: ?graph.ObjectId = null,
};

/// Everything a pure validator needs: local bundle plus optional graph context.
pub const ValidationInput = struct {
    /// Object under validation.
    bundle: graph.ObjectBundle,
    /// Full or partial graph view when cross-object rules need it.
    graph_view: ?*const graph.GraphSnapshot = null,
};

/// Outcome of running one validator once on one input.
pub const ValidationResult = struct {
    /// Which validator produced this result (stable name).
    validator_name: []const u8,
    /// Findings allocated for this result; caller defines ownership contract.
    findings: []const Finding,
};

/// Type-erased validator implemented via vtable (in-process or future plugin host).
pub const Validator = struct {
    /// Implementation state.
    context: *anyopaque,
    /// Virtual methods.
    vtable: *const VTable,

    /// Virtual methods for [`Validator`].
    pub const VTable = struct {
        /// Returns the validator's stable name.
        ///
        /// Parameters:
        /// - `context`: Implementation state (`Validator.context`).
        ///
        /// Returns: a NUL-terminated or slice-backed name valid for the validator's lifetime (implementation-defined).
        name: *const fn (context: *anyopaque) []const u8,
        /// Runs validation; may allocate findings with `allocator`.
        ///
        /// Parameters:
        /// - `context`: Implementation state (`Validator.context`).
        /// - `allocator`: Used to allocate `ValidationResult.findings` and any internal buffers.
        /// - `input`: Bundle and optional graph view to validate.
        ///
        /// Returns: a [`ValidationResult`] on success, or an arbitrary error from the implementation.
        validate: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            input: ValidationInput,
        ) anyerror!ValidationResult,
    };

    /// Stable name for logging, reports, and cache keys.
    ///
    /// Parameters:
    /// - `self`: Type-erased validator.
    ///
    /// Returns: the byte slice returned by the implementation's `name` hook.
    pub fn name(self: Validator) []const u8 {
        return self.vtable.name(self.context);
    }

    /// Runs this validator on the given input.
    ///
    /// Parameters:
    /// - `self`: Type-erased validator.
    /// - `allocator`: Passed to the implementation for allocating findings.
    /// - `input`: Bundle and optional graph to validate.
    ///
    /// Returns: a [`ValidationResult`] on success, or the same error as the underlying `validate` hook.
    pub fn validate(
        self: Validator,
        allocator: std.mem.Allocator,
        input: ValidationInput,
    ) !ValidationResult {
        return self.vtable.validate(self.context, allocator, input);
    }
};

/// Collection of validators exposed to the validate use-case.
pub const ValidatorRegistry = struct {
    /// Registry implementation state.
    context: *anyopaque,
    /// Virtual methods.
    vtable: *const VTable,

    /// Virtual methods for [`ValidatorRegistry`].
    pub const VTable = struct {
        /// Returns all validators to run (order is execution order).
        ///
        /// Parameters:
        /// - `context`: Implementation state (`ValidatorRegistry.context`).
        ///
        /// Returns: a slice of [`Validator`] values valid until the registry implementation mutates.
        list: *const fn (context: *anyopaque) []const Validator,
    };

    /// Slice of validators currently registered.
    ///
    /// Parameters:
    /// - `self`: Type-erased registry.
    ///
    /// Returns: the slice returned by the implementation's `list` hook.
    pub fn list(self: ValidatorRegistry) []const Validator {
        return self.vtable.list(self.context);
    }
};

/// Abstraction for invoking an external validator (e.g. subprocess or WASM later).
pub const PluginRunner = struct {
    /// Runner implementation state.
    context: *anyopaque,
    /// Virtual methods.
    vtable: *const VTable,

    /// Virtual methods for [`PluginRunner`].
    pub const VTable = struct {
        /// Dispatches to a named plugin; encoding is implementation-defined.
        ///
        /// Parameters:
        /// - `context`: Implementation state (`PluginRunner.context`).
        /// - `allocator`: Used for plugin IPC buffers or deserialized results, per implementation.
        /// - `validator_name`: Which plugin or command to run.
        /// - `input`: Same logical input as in-process validators.
        ///
        /// Returns: a [`ValidationResult`] on success, or an arbitrary error from the runner.
        run: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            validator_name: []const u8,
            input: ValidationInput,
        ) anyerror!ValidationResult,
    };

    /// Runs the named plugin as if it were a validator.
    ///
    /// Parameters:
    /// - `self`: Type-erased runner.
    /// - `allocator`: Passed through to the runner implementation.
    /// - `validator_name`: Plugin or validator identifier.
    /// - `input`: Bundle and optional graph for the plugin.
    ///
    /// Returns: a [`ValidationResult`] on success, or the same error as the underlying `run` hook.
    pub fn run(
        self: PluginRunner,
        allocator: std.mem.Allocator,
        validator_name: []const u8,
        input: ValidationInput,
    ) !ValidationResult {
        return self.vtable.run(self.context, allocator, validator_name, input);
    }
};
