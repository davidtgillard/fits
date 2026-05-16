//! Functional tests for persona resolution from argv[0] and search paths.

const std = @import("std");
const persona_resolve = @import("../cli/persona_resolve.zig");
const persona_manifest = @import("../cli/persona_manifest.zig");

test "basenameFromArgv0 strips path and exe" {
    try std.testing.expectEqualStrings("foo", persona_resolve.basenameFromArgv0("/usr/bin/foo"));
    try std.testing.expectEqualStrings("fits", persona_resolve.basenameFromArgv0("fits.exe"));
}

test "resolve default fits persona" {
    const a = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    var resolved = try persona_resolve.resolve(a, std.testing.io, &env_map, "fits", ".");
    defer resolved.deinit(a);
    try std.testing.expect(resolved.is_default);
    try std.testing.expectEqualStrings("fits", resolved.id);
}

test "resolve demo persona from fixture via FITS_PERSONA_PATH" {
    const a = std.testing.allocator;
    const personas_dir = "test/fixtures/personas";
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    try env_map.put("FITS_PERSONA_PATH", personas_dir);

    var resolved = try persona_resolve.resolve(a, std.testing.io, &env_map, "demo", ".");
    defer resolved.deinit(a);
    try std.testing.expect(!resolved.is_default);
    try std.testing.expectEqualStrings("demo", resolved.id);
    try std.testing.expect(resolved.manifest != null);
}

test "isVersionCompatible" {
    try std.testing.expect(persona_manifest.isVersionCompatible("0.1.0", "0.1.0"));
    try std.testing.expect(persona_manifest.isVersionCompatible("0.2.0", "0.1.0"));
    try std.testing.expect(!persona_manifest.isVersionCompatible("0.0.9", "0.1.0"));
}
