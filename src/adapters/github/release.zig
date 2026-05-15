//! GitHub Releases client for the rolling `dev` tag (manifest + binary assets).

const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;

pub const Manifest = struct {
    git_commit: []const u8,
    sha256: []const u8,
};

pub const ReleaseNotFound = error.ReleaseNotFound;
pub const HttpError = error.HttpError;
pub const AssetNotFound = error.AssetNotFound;
pub const InvalidManifest = error.InvalidManifest;

const ReleaseJson = struct {
    assets: []AssetJson,
};

const AssetJson = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const ManifestJson = struct {
    git_commit: []const u8,
    sha256: []const u8,
};

/// Fetches and parses `manifest.json` from the `dev` release.
pub fn fetchDevManifest(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Manifest {
    const body = try downloadReleaseAsset(allocator, io, environ, "manifest.json");
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(ManifestJson, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value.git_commit.len != 40) return InvalidManifest;

    const git_commit = try allocator.dupe(u8, parsed.value.git_commit);
    errdefer allocator.free(git_commit);
    const sha256 = try allocator.dupe(u8, parsed.value.sha256);
    errdefer allocator.free(sha256);

    return .{ .git_commit = git_commit, .sha256 = sha256 };
}

/// Downloads the `fits` binary asset from the `dev` release.
pub fn downloadDevBinary(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    return downloadReleaseAsset(allocator, io, environ, "fits");
}

fn downloadReleaseAsset(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    asset_name: []const u8,
) ![]u8 {
    const owner = build_options.github_owner;
    const repo = build_options.github_repo;

    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/dev", .{ owner, repo });
    defer allocator.free(api_url);

    const release_body = try httpGet(allocator, io, environ, api_url, .api);
    defer allocator.free(release_body);

    const parsed = try std.json.parseFromSlice(ReleaseJson, allocator, release_body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    for (parsed.value.assets) |asset| {
        if (std.mem.eql(u8, asset.name, asset_name)) {
            return httpGet(allocator, io, environ, asset.browser_download_url, .asset);
        }
    }
    return AssetNotFound;
}

const RequestKind = enum { api, asset };

fn httpGet(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    url: []const u8,
    kind: RequestKind,
) ![]u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var headers: [4]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "User-Agent", .value = "fits-cli" };
    n += 1;
    if (kind == .api) {
        headers[n] = .{ .name = "Accept", .value = "application/vnd.github+json" };
        n += 1;
    }

    var auth_owned: ?[]u8 = null;
    defer if (auth_owned) |a| allocator.free(a);

    if (readAuthToken(environ)) |token| {
        auth_owned = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        headers[n] = .{ .name = "Authorization", .value = auth_owned.? };
        n += 1;
    }

    var body_list: std.ArrayList(u8) = .empty;
    defer body_list.deinit(allocator);
    var body_writer = std.Io.Writer.fromArrayList(&body_list);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = headers[0..n],
        .response_writer = &body_writer,
    });

    if (result.status != .ok) return if (result.status == .not_found) ReleaseNotFound else HttpError;
    return body_list.toOwnedSlice(allocator);
}

fn readAuthToken(environ: *const std.process.Environ.Map) ?[]const u8 {
    return environ.get("FITS_GITHUB_TOKEN") orelse environ.get("GITHUB_TOKEN");
}

/// Parses a lowercase hex SHA-256 digest into 32 bytes.
pub fn parseSha256Hex(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        out[i] = try std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16);
    }
    return out;
}

/// Formats 32 digest bytes as lowercase hex into a 64-byte buffer.
pub fn formatSha256Hex(digest: [32]u8, out: *[64]u8) void {
    const hex_digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_digits[byte >> 4];
        out[i * 2 + 1] = hex_digits[byte & 0xf];
    }
}

test "parseSha256Hex roundtrip" {
    var expected: [32]u8 = undefined;
    @memset(&expected, 0xab);
    var hex: [64]u8 = undefined;
    formatSha256Hex(expected, &hex);
    try std.testing.expectEqual(expected, try parseSha256Hex(&hex));
}
