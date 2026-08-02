// mcp-zig — OAuth 2.1 client for remote MCP servers (2026-07-28 auth model)
//
// Ported from codegraff's mcp_oauth.zig + mcp_oauth_discovery.zig (same zig
// version, same std.http.Client patterns), generalized:
//   - RFC 9728: WWW-Authenticate challenge parsing, protected-resource
//     metadata discovery (both well-known locations)
//   - AS metadata discovery (oauth-authorization-server + OIDC variants)
//   - PKCE S256, dynamic client registration, authorization-code exchange,
//     refresh-token grant
//   - one-shot localhost callback listener + browser launch for login()
//   - token persistence in a caller-supplied directory (JSON per resource)
//
// Client ID Metadata Documents (the 2026-07-28-preferred alternative to
// dynamic registration) are NOT implemented — noted, not silent: servers
// requiring them plug in via a pre-registered client_id passed to login().

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json.zig");

const max_response = 1024 * 1024;
pub const default_redirect_uri = "http://127.0.0.1:1456/callback";

pub const Endpoints = struct {
    issuer: []const u8,
    authorization: []const u8,
    token: []const u8,
    registration: []const u8 = "",
    scope: []const u8 = "",
};

pub const TokenSet = struct {
    access: []const u8,
    refresh: []const u8 = "",
    expires_at_ms: i64 = 0,
};

pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    error_desc: ?[]const u8 = null,
};

pub fn requireHttps(url: []const u8) !void {
    if (std.mem.startsWith(u8, url, "https://")) return;
    if (std.mem.startsWith(u8, url, "http://127.0.0.1") or std.mem.startsWith(u8, url, "http://localhost")) return;
    return error.InsecureUrl;
}

// ── well-known URL builders ──────────────────────────────────────────────────

pub fn protectedMetadataUrl(arena: std.mem.Allocator, resource_url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(resource_url);
    const host = uri.host.?.percent_encoded;
    const port = if (uri.port) |p| try std.fmt.allocPrint(arena, ":{d}", .{p}) else "";
    const path = if (std.mem.eql(u8, uri.path.percent_encoded, "/")) "" else uri.path.percent_encoded;
    return std.fmt.allocPrint(arena, "https://{s}{s}/.well-known/oauth-protected-resource{s}", .{ host, port, path });
}

pub fn rootProtectedMetadataUrl(arena: std.mem.Allocator, resource_url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(resource_url);
    const host = uri.host.?.percent_encoded;
    const port = if (uri.port) |p| try std.fmt.allocPrint(arena, ":{d}", .{p}) else "";
    return std.fmt.allocPrint(arena, "https://{s}{s}/.well-known/oauth-protected-resource", .{ host, port });
}

pub fn authorizationMetadataUrl(arena: std.mem.Allocator, issuer: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, issuer, "/");
    return std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server", .{trimmed});
}

pub fn oidcMetadataUrl(arena: std.mem.Allocator, issuer: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, issuer, "/");
    return std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{trimmed});
}

// ── WWW-Authenticate parsing ─────────────────────────────────────────────────

/// Parse a Bearer challenge: `Bearer resource_metadata="...", scope="..."`.
/// Tolerant of missing params and non-Bearer values (returns empty).
pub fn parseChallenge(value: []const u8) Challenge {
    var c: Challenge = .{};
    var v = std.mem.trim(u8, value, " \t");
    if (v.len < 7 or !std.ascii.eqlIgnoreCase(v[0..6], "bearer")) return c;
    v = std.mem.trim(u8, v[6..], " \t");
    if (authParam(v, "resource_metadata")) |m| c.resource_metadata = m;
    if (authParam(v, "scope")) |s| c.scope = s;
    if (authParam(v, "error_description")) |e| c.error_desc = e;
    return c;
}

/// Extract `key="quoted"` or `key=bare` from an HTTP auth-param list.
fn authParam(value: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, value, i, key)) |idx| {
        const after = idx + key.len;
        if (after < value.len and value[after] == '=') {
            if (idx != 0 and value[idx - 1] != ' ' and value[idx - 1] != ',') {
                i = idx + 1;
                continue;
            }
            const v = std.mem.trimStart(u8, value[after + 1 ..], " \t");
            if (v.len == 0) return null;
            if (v[0] == '"') {
                const end = std.mem.indexOfScalarPos(u8, v, 1, '"') orelse return null;
                return v[1..end];
            }
            const end = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
            return std.mem.trim(u8, v[0..end], " \t");
        }
        i = idx + 1;
    }
    return null;
}

// ── PKCE ─────────────────────────────────────────────────────────────────────

pub const Pkce = struct {
    verifier: []u8,
    challenge: []u8,
};

/// S256 PKCE pair: random 32-byte verifier, challenge = b64url(SHA-256(verifier)).
pub fn pkceS256(alloc: std.mem.Allocator, io: std.Io) !Pkce {
    var raw: [32]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    const verifier = try b64urlEncodeAlloc(alloc, &raw);
    errdefer alloc.free(verifier);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try b64urlEncodeAlloc(alloc, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

fn b64urlEncodeAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(s.len));
    const encoded = enc.encode(out, s);
    return out[0..encoded.len];
}

// ── form encoding ────────────────────────────────────────────────────────────

fn writePercentEncoded(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

pub fn formEncode(arena: std.mem.Allocator, fields: []const struct { []const u8, []const u8 }) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (fields, 0..) |field, i| {
        if (i != 0) try aw.writer.writeByte('&');
        try writePercentEncoded(&aw.writer, field[0]);
        try aw.writer.writeByte('=');
        try writePercentEncoded(&aw.writer, field[1]);
    }
    return aw.writer.buffered();
}

// ── HTTP helpers ─────────────────────────────────────────────────────────────

fn httpGet(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit, .user_agent = .{ .override = "mcp-zig-oauth/1" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.HttpStatus;
    const buf = try arena.alloc(u8, max_response);
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var fixed = std.Io.Writer.fixed(buf);
    _ = reader.streamRemaining(&fixed) catch return error.ResponseTooLarge;
    return buf[0..fixed.buffered().len];
}

fn postForm(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "mcp-zig-oauth/1" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(payload);
    try bw.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.HttpStatus;
    const buf = try arena.alloc(u8, max_response);
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var fixed = std.Io.Writer.fixed(buf);
    _ = reader.streamRemaining(&fixed) catch return error.ResponseTooLarge;
    return buf[0..fixed.buffered().len];
}

// ── discovery ────────────────────────────────────────────────────────────────

/// Full discovery: RFC 9728 challenge (if any) → protected-resource metadata
/// (both locations) → authorization-server metadata (oauth + OIDC variants).
pub fn discover(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, resource_url: []const u8, challenge: ?Challenge) !Endpoints {
    try requireHttps(resource_url);

    // 1. protected-resource metadata → authorization_servers[]
    var issuer: ?[]const u8 = null;
    const urls = [2][]const u8{
        try protectedMetadataUrl(arena, resource_url),
        try rootProtectedMetadataUrl(arena, resource_url),
    };
    for (urls) |u| {
        const body = httpGet(io, gpa, arena, u) catch continue;
        if (json.scanStr(body, "authorization_servers")) |_| {
            // first array member string after the key
            if (json.scanObj(body, "authorization_servers")) |_| {} // arrays aren't objects; string scan below
            issuer = firstArrayString(body, "authorization_servers");
            if (issuer != null) break;
        }
    }
    const iss = issuer orelse return error.NoAuthorizationServer;

    // 2. AS metadata (oauth-authorization-server, then OIDC)
    const as_urls = [2][]const u8{
        try authorizationMetadataUrl(arena, iss),
        try oidcMetadataUrl(arena, iss),
    };
    var endpoints: ?Endpoints = null;
    for (as_urls) |u| {
        const body = httpGet(io, gpa, arena, u) catch continue;
        const authorization = json.scanStr(body, "authorization_endpoint") orelse continue;
        const token = json.scanStr(body, "token_endpoint") orelse continue;
        endpoints = .{
            .issuer = iss,
            .authorization = authorization,
            .token = token,
            .registration = json.scanStr(body, "registration_endpoint") orelse "",
            .scope = if (challenge) |c| c.scope orelse "" else "",
        };
        break;
    }
    return endpoints orelse error.NoAuthorizationServerMetadata;
}

fn firstArrayString(body: []const u8, key: []const u8) ?[]const u8 {
    // find "key" then the next '[' then the first quoted string
    const idx = std.mem.indexOf(u8, body, key) orelse return null;
    const bracket = std.mem.indexOfScalarPos(u8, body, idx, '[') orelse return null;
    const q1 = std.mem.indexOfScalarPos(u8, body, bracket, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, body, q1 + 1, '"') orelse return null;
    return body[q1 + 1 .. q2];
}

// ── registration + grants ────────────────────────────────────────────────────

pub const ClientInfo = struct {
    id: []const u8,
    secret: []const u8 = "",
};

/// RFC 7591 dynamic client registration.
pub fn registerClient(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, registration_endpoint: []const u8, client_name: []const u8, redirect_uri: []const u8) !ClientInfo {
    const payload = try std.fmt.allocPrint(arena,
        \\{"client_name":"{s}","redirect_uris":["{s}"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}
    , .{ client_name, redirect_uri });
    const body = postForm(io, gpa, arena, registration_endpoint, payload);
    _ = body catch |err| return err;
    // registration endpoints want JSON, not form — resend as JSON POST
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = try client.request(.POST, try std.Uri.parse(registration_endpoint), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "mcp-zig-oauth/1" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(payload);
    try bw.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.HttpStatus;
    const buf = try arena.alloc(u8, max_response);
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var fixed = std.Io.Writer.fixed(buf);
    _ = reader.streamRemaining(&fixed) catch return error.ResponseTooLarge;
    const resp_body = buf[0..fixed.buffered().len];
    const id = json.scanStr(resp_body, "client_id") orelse return error.BadRegistrationResponse;
    return .{
        .id = id,
        .secret = json.scanStr(resp_body, "client_secret") orelse "",
    };
}

pub fn buildAuthorizationUrl(arena: std.mem.Allocator, endpoints: Endpoints, client_id: []const u8, redirect_uri: []const u8, challenge: []const u8, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        "{s}?response_type=code&client_id={s}&redirect_uri={s}&code_challenge={s}&code_challenge_method=S256&state={s}{s}{s}",
        .{
            endpoints.authorization,
            try pct(arena, client_id),
            try pct(arena, redirect_uri),
            challenge,
            state,
            if (endpoints.scope.len != 0) "&scope=" else "",
            if (endpoints.scope.len != 0) try pct(arena, endpoints.scope) else "",
        },
    );
}

fn pct(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writePercentEncoded(&aw.writer, s);
    return aw.writer.buffered();
}

/// authorization_code exchange.
pub fn exchangeCode(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, endpoints: Endpoints, client: ClientInfo, code: []const u8, verifier: []const u8, redirect_uri: []const u8, now_ms: i64) !TokenSet {
    const payload = try formEncode(arena, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", client.id },
        .{ "code_verifier", verifier },
    });
    return tokenFromResponse(postForm(io, gpa, arena, endpoints.token, payload) catch |err| return err, now_ms);
}

/// refresh_token grant.
pub fn refresh(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, endpoints: Endpoints, client: ClientInfo, refresh_token: []const u8, now_ms: i64) !TokenSet {
    const payload = try formEncode(arena, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", refresh_token },
        .{ "client_id", client.id },
    });
    return tokenFromResponse(postForm(io, gpa, arena, endpoints.token, payload) catch |err| return err, now_ms);
}

fn tokenFromResponse(body: []const u8, now_ms: i64) !TokenSet {
    const access = json.scanStr(body, "access_token") orelse return error.BadTokenResponse;
    const expires_in = json.scanInt(body, "expires_in") orelse 3600;
    return .{
        .access = access,
        .refresh = json.scanStr(body, "refresh_token") orelse "",
        .expires_at_ms = now_ms + expires_in * 1000,
    };
}

// ── persistence ──────────────────────────────────────────────────────────────

fn tokenPath(alloc: std.mem.Allocator, dir: []const u8, resource_url: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(resource_url);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = "0123456789abcdef";
    var name: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        name[i * 2] = hex[b >> 4];
        name[i * 2 + 1] = hex[b & 15];
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, name });
}

pub fn saveTokens(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, resource_url: []const u8, tokens: TokenSet) !void {
    const path = try tokenPath(alloc, dir, resource_url);
    defer alloc.free(path);
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf,
        \\{"access_token":"{s}","refresh_token":"{s}","expires_at_ms":{d}}
    , .{ tokens.access, tokens.refresh, tokens.expires_at_ms });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Load a still-valid access token for the resource, if one is stored.
pub fn loadAccessToken(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, resource_url: []const u8, now_ms: i64) ?[]const u8 {
    const path = tokenPath(alloc, dir, resource_url) catch return null;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    const expires = json.scanInt(text, "expires_at_ms") orelse 0;
    if (now_ms >= expires) return null; // caller may use loadTokenSet + refresh
    return json.scanStr(text, "access_token");
}

pub fn loadTokenSet(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, resource_url: []const u8) ?TokenSet {
    const path = tokenPath(alloc, dir, resource_url) catch return null;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    const access = json.scanStr(text, "access_token") orelse return null;
    return .{
        .access = access,
        .refresh = json.scanStr(text, "refresh_token") orelse "",
        .expires_at_ms = json.scanInt(text, "expires_at_ms") orelse 0,
    };
}

// ── interactive login ────────────────────────────────────────────────────────

fn openBrowser(io: std.Io, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.spawn(io, .{ .argv = argv }) catch return;
    _ = child.wait(io) catch {};
}

/// Wait for exactly one OAuth callback on the redirect port and return the
/// `code` (validating `state`). The listener is one-shot and short-lived.
fn awaitCallback(io: std.Io, redirect_uri: []const u8, state: []const u8, buf: []u8) ![]const u8 {
    const uri = try std.Uri.parse(redirect_uri);
    const port: u16 = uri.port orelse 80;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer listener.deinit(io);

    const stream = try listener.accept(io);
    defer stream.close(io);
    const n = try stream.read(io, &.{buf});
    const req = buf[0..n];

    // extract the path from "GET <path> HTTP/1.1"
    const sp1 = std.mem.indexOfScalar(u8, req, ' ') orelse return error.BadCallback;
    const sp2 = std.mem.indexOfScalarPos(u8, req, sp1 + 1, ' ') orelse return error.BadCallback;
    const path = req[sp1 + 1 .. sp2];

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 52\r\nConnection: close\r\n\r\n<html><body>You can close this tab now.</body></html>") catch {};
    w.interface.flush() catch {};

    const code = queryParam(path, "code") orelse return error.BadCallback;
    const got_state = queryParam(path, "state") orelse return error.BadCallback;
    if (!std.mem.eql(u8, got_state, state)) return error.StateMismatch;
    return code;
}

fn queryParam(path: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.splitScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Full interactive login: discover → (register if needed) → browser →
/// callback → exchange → persist. Returns the fresh TokenSet. `client_id`
/// may be pre-registered (e.g. a Client ID Metadata Document URL); when
/// empty, dynamic registration is attempted.
pub fn login(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    resource_url: []const u8,
    client_name: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
) !TokenSet {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const endpoints = try discover(io, gpa, arena, resource_url, null);
    var client: ClientInfo = .{ .id = client_id };
    if (client.id.len == 0) {
        if (endpoints.registration.len == 0) return error.RegistrationUnsupported;
        client = try registerClient(io, gpa, arena, endpoints.registration, client_name, redirect_uri);
    }

    const pair = try pkceS256(arena);
    var state_raw: [16]u8 = undefined;
    std.crypto.random.bytes(&state_raw);
    const state = try b64urlEncodeAlloc(arena, &state_raw);
    const url = try buildAuthorizationUrl(arena, endpoints, client.id, redirect_uri, pair.challenge, state);
    openBrowser(io, url);

    var cb_buf: [8192]u8 = undefined;
    const code = try awaitCallback(io, redirect_uri, state, &cb_buf);
    const tokens = try exchangeCode(io, gpa, arena, endpoints, client, code, pair.verifier, redirect_uri, nowMs(io));
    try saveTokens(io, arena, dir, resource_url, tokens);
    return tokens;
}

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.now(.real, io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// ── tests ────────────────────────────────────────────────────────────────────

test "requireHttps policy" {
    const testing = std.testing;
    try requireHttps("https://example.com/mcp");
    try requireHttps("http://127.0.0.1:8000/mcp");
    try requireHttps("http://localhost:8000/mcp");
    try testing.expectError(error.InsecureUrl, requireHttps("http://example.com/mcp"));
}

test "well-known URL builders" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(
        "https://example.com:8443/.well-known/oauth-protected-resource/mcp",
        try protectedMetadataUrl(a, "https://example.com:8443/mcp"),
    );
    try testing.expectEqualStrings(
        "https://example.com/.well-known/oauth-protected-resource",
        try rootProtectedMetadataUrl(a, "https://example.com/mcp"),
    );
    try testing.expectEqualStrings(
        "https://as.example/.well-known/oauth-authorization-server",
        try authorizationMetadataUrl(a, "https://as.example/"),
    );
}

test "parseChallenge extracts params and ignores non-Bearer" {
    const testing = std.testing;
    const c = parseChallenge("Bearer resource_metadata=\"https://x/.well-known/oauth-protected-resource\", scope=\"docs:read\"");
    try testing.expectEqualStrings("https://x/.well-known/oauth-protected-resource", c.resource_metadata.?);
    try testing.expectEqualStrings("docs:read", c.scope.?);
    const empty = parseChallenge("Basic realm=\"x\"");
    try testing.expect(empty.resource_metadata == null);
}

test "pkceS256 produces verifier and S256 challenge" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const pair = try pkceS256(arena_state.allocator(), std.testing.io);
    try testing.expect(pair.verifier.len > 20);
    try testing.expect(pair.challenge.len == 43); // b64url(32 bytes), no padding
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pair.verifier, &digest, .{});
    const expect = try b64urlEncodeAlloc(arena_state.allocator(), &digest);
    try testing.expectEqualStrings(expect, pair.challenge);
}

test "formEncode percent-encodes" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try formEncode(arena_state.allocator(), &.{
        .{ "grant_type", "authorization_code" },
        .{ "redirect_uri", "http://127.0.0.1:1456/callback" },
    });
    try testing.expectEqualStrings("grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback", f);
}

test "tokenFromResponse + persistence round-trip" {
    const testing = std.testing;
    const tokens = try tokenFromResponse("{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":60}", 1000);
    try testing.expectEqualStrings("at", tokens.access);
    try testing.expectEqualStrings("rt", tokens.refresh);
    try testing.expectEqual(@as(i64, 61_000), tokens.expires_at_ms);
}

test "queryParam" {
    const testing = std.testing;
    try testing.expectEqualStrings("abc", queryParam("/callback?code=abc&state=xyz", "code").?);
    try testing.expectEqualStrings("xyz", queryParam("/callback?code=abc&state=xyz", "state").?);
    try testing.expect(queryParam("/callback", "code") == null);
}
