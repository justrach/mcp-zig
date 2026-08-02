// mcp-zig — HTTP authorization (2026-07-28 Streamable HTTP security)
//
// Bearer-token scaffolding for the HTTP transport:
//   - `Authorization: Bearer <token>` required on the MCP endpoint when enabled
//   - 401 + WWW-Authenticate challenge per RFC 6750 / the MCP auth spec
//   - RFC 9728 protected-resource metadata at a well-known path (public)
//   - HS256 JWT validation via std.crypto HMAC-SHA256, plus a pluggable
//     validator callback for products with their own token store
//
// Deliberately out of scope (documented, not silent): acting as an OAuth
// authorization server, RS*/ES* JWKS verification (std.crypto has no RSA/EC
// public-key verify for those curves), and Client ID Metadata Document
// fetching. Products needing those plug in via AuthConfig.validator.

const std = @import("std");
const json = @import("json.zig");

/// Bearer-token authorization configuration for the HTTP transport.
pub const AuthConfig = struct {
    /// Issuer identifier; when non-empty, JWT `iss` must match.
    issuer: []const u8 = "",
    /// Audience; when non-empty, JWT `aud` (string form) must match.
    audience: []const u8 = "",
    /// HMAC-SHA256 secret for HS256 JWTs. Used when `validator` is null.
    hs256_secret: ?[]const u8 = null,
    /// Custom validator (raw bearer token → allowed?). Wins over hs256_secret.
    validator: ?*const fn (token: []const u8) bool = null,
};

/// Validate a raw bearer token against the config.
/// `now_secs` is the current wall-clock time (for `exp`) — callers with an
/// std.Io get it via `@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)`.
pub fn validate(auth: AuthConfig, token: []const u8, now_secs: i64) bool {
    if (auth.validator) |v| return v(token);
    const secret = auth.hs256_secret orelse return false;
    return validateHs256Jwt(secret, auth.issuer, auth.audience, token, now_secs);
}

/// Validate an HS256 JSON Web Token: signature, alg, exp, iss, aud.
pub fn validateHs256Jwt(secret: []const u8, issuer: []const u8, audience: []const u8, token: []const u8, now_secs: i64) bool {
    var parts: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, token, '.');
    parts[0] = it.next() orelse return false;
    parts[1] = it.next() orelse return false;
    parts[2] = it.next() orelse return false;
    if (it.next() != null) return false;

    var buf: [4096]u8 = undefined;

    // Header: alg must be HS256.
    const header = b64urlDecode(&buf, parts[0]) orelse return false;
    const alg = json.scanStr(header, "alg") orelse return false;
    if (!std.mem.eql(u8, alg, "HS256")) return false;

    // Signature: HMAC-SHA256 over "<h>.<p>", base64url-decoded and compared
    // in constant time.
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, token[0 .. parts[0].len + 1 + parts[1].len], secret);
    const sig = b64urlDecode(buf[2048..], parts[2]) orelse return false;
    if (sig.len != mac.len) return false;
    if (!std.crypto.timing_safe.eql([32]u8, mac, sig[0..32].*)) return false;

    // Payload claims.
    const payload = b64urlDecode(buf[1024..], parts[1]) orelse return false;
    if (json.scanInt(payload, "exp")) |exp| {
        if (now_secs >= exp) return false;
    }
    if (issuer.len != 0) {
        const iss = json.scanStr(payload, "iss") orelse return false;
        if (!std.mem.eql(u8, iss, issuer)) return false;
    }
    if (audience.len != 0) {
        const aud = json.scanStr(payload, "aud") orelse return false;
        if (!std.mem.eql(u8, aud, audience)) return false;
    }
    return true;
}

fn b64urlDecode(buf: []u8, s: []const u8) ?[]const u8 {
    const n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(s) catch return null;
    if (n > buf.len) return null;
    std.base64.url_safe_no_pad.Decoder.decode(buf[0..n], s) catch return null;
    return buf[0..n];
}

/// RFC 9728 protected-resource metadata (served WITHOUT authentication).
pub fn appendProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    resource_url: []const u8,
    issuer: []const u8,
) void {
    out.appendSlice(allocator, "{\"resource\":\"") catch return;
    json.writeEscaped(allocator, out, resource_url);
    out.appendSlice(allocator, "\",\"authorization_servers\":[") catch return;
    if (issuer.len != 0) {
        out.appendSlice(allocator, "\"") catch return;
        json.writeEscaped(allocator, out, issuer);
        out.appendSlice(allocator, "\"") catch return;
    }
    out.appendSlice(allocator, "],\"bearer_methods_supported\":[\"header\"],\"scopes_supported\":[]}") catch return;
}

// ── tests ────────────────────────────────────────────────────────────────────

fn b64urlEncodeAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(s.len));
    const encoded = enc.encode(out, s);
    return out[0..encoded.len];
}

fn mintTestJwt(alloc: std.mem.Allocator, secret: []const u8, payload: []const u8) ![]u8 {
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const h64 = try b64urlEncodeAlloc(alloc, header);
    defer alloc.free(h64);
    try out.appendSlice(alloc, h64);
    try out.append(alloc, '.');
    const p64 = try b64urlEncodeAlloc(alloc, payload);
    defer alloc.free(p64);
    try out.appendSlice(alloc, p64);
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, out.items, secret);
    try out.append(alloc, '.');
    const s64 = try b64urlEncodeAlloc(alloc, &mac);
    defer alloc.free(s64);
    try out.appendSlice(alloc, s64);
    return out.toOwnedSlice(alloc);
}

test "HS256 JWT validation: good, bad signature, wrong issuer, expired" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const secret = "top-secret";
    const now: i64 = 1_800_000_000;
    const future = now + 3600;

    const good_payload = try std.fmt.allocPrint(alloc, "{{\"iss\":\"me\",\"aud\":\"mcp\",\"exp\":{d}}}", .{future});
    defer alloc.free(good_payload);
    const good = try mintTestJwt(alloc, secret, good_payload);
    defer alloc.free(good);

    try testing.expect(validateHs256Jwt(secret, "me", "mcp", good, now));
    try testing.expect(validateHs256Jwt(secret, "", "", good, now)); // no iss/aud configured → claims not required
    try testing.expect(!validateHs256Jwt(secret, "someone-else", "mcp", good, now));
    try testing.expect(!validateHs256Jwt(secret, "me", "other-aud", good, now));
    try testing.expect(!validateHs256Jwt("wrong-secret", "me", "mcp", good, now));

    // expired
    const old_payload = try std.fmt.allocPrint(alloc, "{{\"iss\":\"me\",\"exp\":{d}}}", .{now - 10});
    defer alloc.free(old_payload);
    const old = try mintTestJwt(alloc, secret, old_payload);
    defer alloc.free(old);
    try testing.expect(!validateHs256Jwt(secret, "", "", old, now));

    // malformed
    try testing.expect(!validateHs256Jwt(secret, "", "", "not-a-jwt", now));
    try testing.expect(!validateHs256Jwt(secret, "", "", "a.b.c.d", now));

    // validator callback wins over HS256
    const cfg: AuthConfig = .{ .validator = struct {
        fn v(token: []const u8) bool {
            return std.mem.eql(u8, token, "let-me-in");
        }
    }.v };
    try testing.expect(validate(cfg, "let-me-in", now));
    try testing.expect(!validate(cfg, good, now));
}

test "protected resource metadata shape" {
    const testing = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    appendProtectedResourceMetadata(testing.allocator, &out, "http://127.0.0.1:8000/mcp", "me");
    try testing.expect(std.mem.indexOf(u8, out.items, "\"resource\":\"http://127.0.0.1:8000/mcp\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"authorization_servers\":[\"me\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"bearer_methods_supported\":[\"header\"]") != null);
}

test "HS256 JWT: non-HS256 alg, missing exp, bad base64, metadata without issuer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const secret = "top-secret";
    const now: i64 = 1_800_000_000;

    // alg != HS256 must reject even with a valid HMAC
    const none_header = "{\"alg\":\"none\"}";
    const h64 = try b64urlEncodeAlloc(alloc, none_header);
    defer alloc.free(h64);
    const p64 = try b64urlEncodeAlloc(alloc, "{}");
    defer alloc.free(p64);
    const s64 = try b64urlEncodeAlloc(alloc, "x");
    defer alloc.free(s64);
    const fake = try std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ h64, p64, s64 });
    defer alloc.free(fake);
    try testing.expect(!validateHs256Jwt(secret, "", "", fake, now));

    // no exp claim → allowed (exp is optional)
    const no_exp = try mintTestJwt(alloc, secret, "{\"iss\":\"me\"}");
    defer alloc.free(no_exp);
    try testing.expect(validateHs256Jwt(secret, "me", "", no_exp, now));

    // invalid base64 segments → reject, never panic
    try testing.expect(!validateHs256Jwt(secret, "", "", "!!!.@@@.###", now));
    try testing.expect(!validateHs256Jwt(secret, "", "", "..", now));
    try testing.expect(!validateHs256Jwt(secret, "", "", "", now));

    // metadata with empty issuer → empty authorization_servers array
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    appendProtectedResourceMetadata(alloc, &out, "http://h:1/mcp", "");
    try testing.expect(std.mem.indexOf(u8, out.items, "\"authorization_servers\":[]") != null);
}
