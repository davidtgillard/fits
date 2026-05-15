//! Local cache abstraction backed by LatticeDB (stub implementation).

const std = @import("std");

/// Key-value cache used to accelerate repeated validation or graph builds.
pub const CacheStore = struct {
    /// Cache implementation state.
    context: *anyopaque,
    /// Virtual methods.
    vtable: *const VTable,

    /// Virtual methods for [`CacheStore`].
    pub const VTable = struct {
        /// Stores a value under `key` (replaces if present; semantics TBD).
        ///
        /// Parameters:
        /// - `context`: Implementation state (`CacheStore.context`).
        /// - `key`: Cache key bytes.
        /// - `value`: Value bytes to associate with `key`.
        ///
        /// Returns: nothing on success, or an arbitrary error from the implementation.
        put: *const fn (context: *anyopaque, key: []const u8, value: []const u8) anyerror!void,
        /// Returns the value for `key`, or `null` if missing.
        ///
        /// Parameters:
        /// - `context`: Implementation state (`CacheStore.context`).
        /// - `key`: Cache key to look up.
        ///
        /// Returns: owned or borrowed value bytes on hit (`non-null`), or `null` on miss, or an error from the implementation.
        get: *const fn (context: *anyopaque, key: []const u8) anyerror!?[]const u8,
    };

    /// Writes through to the implementation.
    ///
    /// Parameters:
    /// - `self`: Type-erased cache.
    /// - `key`: Key to store under.
    /// - `value`: Value to store.
    ///
    /// Returns: nothing on success, or the same error as the underlying `put` hook.
    pub fn put(self: CacheStore, key: []const u8, value: []const u8) !void {
        return self.vtable.put(self.context, key, value);
    }

    /// Reads through to the implementation.
    ///
    /// Parameters:
    /// - `self`: Type-erased cache.
    /// - `key`: Key to look up.
    ///
    /// Returns: `null` if missing, a value slice on hit, or an error from the implementation.
    pub fn get(self: CacheStore, key: []const u8) !?[]const u8 {
        return self.vtable.get(self.context, key);
    }
};

/// No-op cache placeholder until LatticeDB is wired in.
pub const LatticeDbCache = struct {
    /// Allocator retained for future real backing store allocations.
    allocator: std.mem.Allocator,

    /// Creates a stub cache instance.
    ///
    /// Parameters:
    /// - `allocator`: Retained for future LatticeDB integration; currently unused by the stub.
    ///
    /// Returns: an initialized [`LatticeDbCache`] value.
    pub fn init(allocator: std.mem.Allocator) LatticeDbCache {
        return .{
            .allocator = allocator,
        };
    }

    /// Exposes this value as a [`CacheStore`].
    ///
    /// Parameters:
    /// - `self`: Must outlive any `get`/`put` calls on the returned [`CacheStore`].
    ///
    /// Returns: a [`CacheStore`] whose context pointer aliases `self`.
    pub fn asInterface(self: *LatticeDbCache) CacheStore {
        return .{
            .context = self,
            .vtable = &.{
                .put = putAdapter,
                .get = getAdapter,
            },
        };
    }

    // Vtable: no-op store.
    fn putAdapter(context: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *LatticeDbCache = @ptrCast(@alignCast(context));
        _ = self;
        _ = key;
        _ = value;
    }

    // Vtable: always miss.
    fn getAdapter(context: *anyopaque, key: []const u8) anyerror!?[]const u8 {
        const self: *LatticeDbCache = @ptrCast(@alignCast(context));
        _ = self;
        _ = key;
        return null;
    }
};
