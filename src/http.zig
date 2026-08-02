// mcp-zig — Streamable HTTP transport, phase 1.
//
// This serves MCP JSON-RPC over POST /mcp. It deliberately keeps stdio
// unchanged and reuses the existing tool registry/dispatch path.

const std = @import("std");
const json = @import("json.zig");
const protocol = @import("mcp.zig");
const auth_mod = @import("auth.zig");
const default_tools = @import("tools.zig");

const PROTOCOL_VERSION = protocol.PROTOCOL_VERSION;

pub const AuthConfig = auth_mod.AuthConfig;

const MAX_REQUEST_BYTES = 1024 * 1024;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8000,
    /// When set, the MCP endpoint requires a valid `Authorization: Bearer`
    /// token on every request (2026-07-28 security), and the RFC 9728
    /// protected-resource metadata document is served publicly.
    auth: ?AuthConfig = null,
};

const SessionStore = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    ids: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) SessionStore {
        return .{
            .allocator = allocator,
            .ids = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *SessionStore) void {
        var it = self.ids.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ids.deinit();
    }

    fn create(self: *SessionStore, protocol_version: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(
            self.allocator,
            "mcp-zig-{d}",
            .{self.next_id},
        );
        errdefer self.allocator.free(id);
        self.next_id += 1;
        try self.ids.put(id, protocol_version);
        return id;
    }

    fn getVersion(self: *SessionStore, id: []const u8) ?[]const u8 {
        return self.ids.get(id);
    }

    fn contains(self: *SessionStore, id: []const u8) bool {
        return self.ids.contains(id);
    }

    fn remove(self: *SessionStore, id: []const u8) bool {
        if (self.ids.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }
};

const Request = struct {
    method: []const u8,
    path: []const u8,
    session_id: ?[]const u8,
    protocol_version: ?[]const u8,
    mcp_method: ?[]const u8,
    mcp_name: ?[]const u8,
    last_event_id: ?[]const u8,
    authorization: ?[]const u8,
    origin: ?[]const u8,
    host: ?[]const u8,
    body: []const u8,
};

const Conn = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    writer: std.Io.net.Stream.Writer,

    fn init(io: std.Io, stream: std.Io.net.Stream, buf: []u8) Conn {
        return .{
            .io = io,
            .stream = stream,
            .writer = stream.writer(io, buf),
        };
    }

    fn writeAll(self: *Conn, bytes: []const u8) void {
        self.writer.interface.writeAll(bytes) catch {};
    }

    fn flush(self: *Conn) void {
        self.writer.interface.flush() catch {};
    }
};

pub fn serve(io: std.Io, allocator: std.mem.Allocator, opts: Options) !void {
    try serveWithRegistry(io, allocator, opts, default_tools);
}

pub fn serveWithRegistry(io: std.Io, allocator: std.mem.Allocator, opts: Options, comptime Registry: type) !void {
    protocol.validateRegistry(Registry);

    const addr = try std.Io.net.IpAddress.parse(opts.host, opts.port);
    var listener = try addr.listen(io, .{
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    });
    defer listener.deinit(io);

    var sessions = SessionStore.init(allocator);
    defer sessions.deinit();

    std.log.info("mcp-zig HTTP transport listening on {s}:{d}", .{ opts.host, opts.port });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return err,
        };
        var detached = false;
        handleConnection(Registry, io, allocator, stream, &sessions, &detached, opts);
        if (!detached) stream.close(io);
    }
}

fn readSome(io: std.Io, stream: std.Io.net.Stream, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    var iov: [1][]u8 = .{dest};
    return try stream.read(io, &iov);
}

fn handleConnection(
    comptime Registry: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    sessions: *SessionStore,
    detached: *bool,
    opts: Options,
) void {
    const request_buf = allocator.alloc(u8, MAX_REQUEST_BYTES) catch return;
    defer allocator.free(request_buf);

    var n = readSome(io, stream, request_buf) catch return;
    if (n == 0) return;

    while (std.mem.indexOf(u8, request_buf[0..n], "\r\n\r\n") == null and n < request_buf.len) {
        const m = readSome(io, stream, request_buf[n..]) catch return;
        if (m == 0) return;
        n += m;
    }

    const header_end = std.mem.indexOf(u8, request_buf[0..n], "\r\n\r\n") orelse return;
    const headers = request_buf[0..header_end];
    const content_length = findContentLength(headers);
    const body_end = header_end + 4 + content_length;
    if (body_end > request_buf.len) {
        var write_buf: [4096]u8 = undefined;
        var conn = Conn.init(io, stream, &write_buf);
        respondJson(&conn, "413 Payload Too Large", "{\"error\":\"request too large\"}", null, PROTOCOL_VERSION);
        return;
    }
    while (n < body_end) {
        const m = readSome(io, stream, request_buf[n..body_end]) catch return;
        if (m == 0) break;
        n += m;
    }

    var write_buf: [4096]u8 = undefined;
    var conn = Conn.init(io, stream, &write_buf);

    const req = parseRequest(request_buf[0..n]) orelse {
        respondJson(&conn, "400 Bad Request", "{\"error\":\"bad request\"}", null, PROTOCOL_VERSION);
        return;
    };

    // RFC 9728: the protected-resource metadata document is PUBLIC — served
    // without a token so clients can discover authorization requirements.
    if (opts.auth) |a| {
        if (std.mem.eql(u8, req.path, "/.well-known/oauth-protected-resource")) {
            respondProtectedResourceMetadata(allocator, &conn, opts, a);
            return;
        }
    }

    if (!std.mem.eql(u8, req.path, "/mcp")) {
        respondJson(&conn, "404 Not Found", "{\"error\":\"not found\"}", null, PROTOCOL_VERSION);
        return;
    }

    // Spec security guidance: validate Origin to prevent DNS-rebinding attacks
    // from browser-based clients. Non-browser clients (no Origin) are allowed.
    if (!originAllowed(req)) {
        respondJson(&conn, "403 Forbidden", "{\"error\":\"origin not allowed\"}", null, PROTOCOL_VERSION);
        return;
    }

    // Bearer-token gate (2026-07-28 security): every request to the MCP
    // endpoint needs a valid token when auth is configured.
    if (opts.auth) |a| {
        const token = bearerToken(req) orelse {
            respondUnauthorized(&conn, opts);
            return;
        };
        const now_secs: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
        if (!auth_mod.validate(a, token, now_secs)) {
            respondUnauthorized(&conn, opts);
            return;
        }
    }

    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        respondEmpty(&conn, "204 No Content", null, PROTOCOL_VERSION);
        return;
    }

    if (std.mem.eql(u8, req.method, "GET")) {
        const session_id = req.session_id orelse {
            respondJson(&conn, "400 Bad Request", "{\"error\":\"missing mcp-session-id\"}", null, PROTOCOL_VERSION);
            return;
        };
        const protocol_version = sessions.getVersion(session_id) orelse {
            respondJson(&conn, "404 Not Found", "{\"error\":\"unknown mcp-session-id\"}", null, PROTOCOL_VERSION);
            return;
        };
        if (req.protocol_version) |header_version| {
            if (!std.mem.eql(u8, header_version, protocol_version)) {
                respondJson(&conn, "400 Bad Request", "{\"error\":\"mcp-protocol-version mismatch\"}", null, protocol_version);
                return;
            }
        }
        respondSseListen(allocator, &conn, session_id, protocol_version, req.last_event_id, detached);
        return;
    }

    if (std.mem.eql(u8, req.method, "DELETE")) {
        const protocol_version = if (req.session_id) |session_id|
            sessions.getVersion(session_id) orelse PROTOCOL_VERSION
        else
            PROTOCOL_VERSION;
        if (req.session_id) |session_id| {
            _ = sessions.remove(session_id);
        }
        respondEmpty(&conn, "204 No Content", null, protocol_version);
        return;
    }

    if (!std.mem.eql(u8, req.method, "POST")) {
        respondJson(&conn, "405 Method Not Allowed", "{\"error\":\"method not allowed\"}", null, PROTOCOL_VERSION);
        return;
    }

    handlePost(Registry, allocator, io, &conn, sessions, req, detached);
}

fn handlePost(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: *Conn,
    sessions: *SessionStore,
    req: Request,
    detached: *bool,
) void {
    const input = std.mem.trim(u8, req.body, " \t\r\n");
    if (input.len == 0) {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        appendRpcError(allocator, &body, null, -32700, "Parse error");
        respondJson(conn, "400 Bad Request", body.items, null, PROTOCOL_VERSION);
        return;
    }

    const scan = json.scanJsonRpc(input);
    const method = scan.method orelse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        appendRpcError(allocator, &body, scan.id_raw, -32600, "Missing method");
        respondJson(conn, "200 OK", body.items, null, PROTOCOL_VERSION);
        return;
    };

    // 2026-07-28 modern gate: a request carrying _meta.protocolVersion opts
    // into stateless mode. The MCP-Protocol-Version header (when present) must
    // match it; unknown versions get the spec-mandated error (HTTP 400).
    const modern = blk: {
        const v = json.metaProtocolVersion(scan.meta_raw) orelse break :blk false;
        if (req.protocol_version) |hv| {
            if (!std.mem.eql(u8, hv, v)) {
                respondJson(conn, "400 Bad Request", "{\"error\":\"mcp-protocol-version header does not match _meta protocolVersion\"}", null, PROTOCOL_VERSION);
                return;
            }
        }
        if (!protocol.isSupportedProtocolVersion(v)) {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(allocator);
            appendUnsupportedProtocolVersion(allocator, &body, scan.id_raw, v);
            respondJson(conn, "400 Bad Request", body.items, null, PROTOCOL_VERSION);
            return;
        }
        break :blk true;
    };

    // server/discover is stateless by design: no session, no initialize.
    if (std.mem.eql(u8, method, "server/discover")) {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        appendRpcResultRawMeta(allocator, &body, scan.id_raw, protocol.discoverResult(Registry), true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
        return;
    }

    // Modern (2026-07-28) requests are self-describing: dispatch statelessly,
    // no session gate. Legacy requests continue below.
    if (modern) {
        handleModernPost(Registry, allocator, io, conn, req, method, &scan, detached);
        return;
    }

    if (std.mem.eql(u8, method, "initialize")) {
        const requested_version = if (scan.params_raw) |params_raw|
            json.scanStr(params_raw, "protocolVersion")
        else
            null;        const negotiated = protocol.negotiateProtocolVersion(requested_version);
        const session_id = sessions.create(negotiated) catch {
            respondJson(conn, "500 Internal Server Error", "{\"error\":\"session create failed\"}", null, PROTOCOL_VERSION);
            return;
        };
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        const init_result = protocol.initializeResultForVersionAlloc(Registry, allocator, negotiated) catch {
            respondJson(conn, "500 Internal Server Error", "{\"error\":\"initialize failed\"}", null, negotiated);
            return;
        };
        defer allocator.free(init_result);
        appendRpcResultRaw(allocator, &body, scan.id_raw, init_result);
        respondJson(conn, "200 OK", body.items, session_id, negotiated);
        return;
    }

    const session_id = req.session_id orelse {
        respondJson(conn, "400 Bad Request", "{\"error\":\"missing mcp-session-id\"}", null, PROTOCOL_VERSION);
        return;
    };
    const protocol_version = sessions.getVersion(session_id) orelse {
        respondJson(conn, "404 Not Found", "{\"error\":\"unknown mcp-session-id\"}", null, PROTOCOL_VERSION);
        return;
    };
    if (req.protocol_version) |header_version| {
        if (!std.mem.eql(u8, header_version, protocol_version)) {
            respondJson(conn, "400 Bad Request", "{\"error\":\"mcp-protocol-version mismatch\"}", null, protocol_version);
            return;
        }
    } else {
        // 2025-11-25: the negotiated-version header is mandatory on all
        // requests after initialize.
        respondJson(conn, "400 Bad Request", "{\"error\":\"missing mcp-protocol-version\"}", null, protocol_version);
        return;
    }

    if (scan.id_raw == null) {
        respondEmpty(conn, "202 Accepted", session_id, protocol_version);
        return;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    if (std.mem.eql(u8, method, "ping")) {
        appendRpcResultRawMeta(allocator, &body, scan.id_raw, "{}", modern);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        appendRpcResultRawMeta(allocator, &body, scan.id_raw, Registry.tools_list, modern);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        appendToolCallResult(Registry, allocator, io, &body, &scan, modern);
    } else if (std.mem.eql(u8, method, "logging/setLevel")) {
        appendRpcResultRawMeta(allocator, &body, scan.id_raw, "{}", modern);
    } else {
        appendRpcError(allocator, &body, scan.id_raw, -32601, "Method not found");
    }

    respondJson(conn, "200 OK", body.items, session_id, protocol_version);
}

// ── Modern (2026-07-28) stateless request path ─────────────────────────────
//
// Self-describing requests (those carrying _meta.protocolVersion) are
// dispatched here with no session and no initialize. Mirrored request-metadata
// headers are validated per the Streamable HTTP spec.

/// HeaderMismatch (-32020): a mirrored header is missing or disagrees with the body.
fn appendHeaderMismatch(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    detail: []const u8,
) void {
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"error\":{\"code\":-32020,\"message\":\"Header mismatch: ") catch return;
    json.writeEscaped(allocator, body, detail);
    body.appendSlice(allocator, "\"}}") catch return;
}

fn headerMismatch(allocator: std.mem.Allocator, conn: *Conn, id_raw: ?[]const u8, detail: []const u8) void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    appendHeaderMismatch(allocator, &body, id_raw, detail);
    respondJson(conn, "400 Bad Request", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
}

fn handleModernPost(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: *Conn,
    req: Request,
    method: []const u8,
    scan: *const json.ScanResult,
    detached: *bool,
) void {
    // Mirrored headers are REQUIRED on requests; notification POST header
    // requirements are undefined by this revision, so they are skipped.
    if (scan.id_raw != null) {
        if (req.protocol_version == null) {
            headerMismatch(allocator, conn, scan.id_raw, "missing MCP-Protocol-Version header");
            return;
        }
        const hm = req.mcp_method orelse {
            headerMismatch(allocator, conn, scan.id_raw, "missing Mcp-Method header");
            return;
        };
        if (!std.mem.eql(u8, hm, method)) {
            headerMismatch(allocator, conn, scan.id_raw, "Mcp-Method does not match body method");
            return;
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            const name = if (scan.params_raw) |p| json.scanStr(p, "name") orelse "" else "";
            const hn = req.mcp_name orelse {
                headerMismatch(allocator, conn, scan.id_raw, "missing Mcp-Name header");
                return;
            };
            if (!std.mem.eql(u8, hn, name)) {
                headerMismatch(allocator, conn, scan.id_raw, "Mcp-Name does not match params.name");
                return;
            }
        }
    }

    // Notifications: accept, no body.
    if (scan.id_raw == null) {
        respondEmpty(conn, "202 Accepted", null, protocol.MODERN_PROTOCOL_VERSION);
        return;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    if (std.mem.eql(u8, method, "tools/list")) {
        // 2026-07-28 ListToolsResult requires resultType, ttlMs, cacheScope.
        body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        body.appendSlice(allocator, scan.id_raw orelse "null") catch return;
        body.appendSlice(allocator, ",\"result\":{" ++ protocol.MODERN_RESULT_META ++ ",\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"public\",") catch return;
        body.appendSlice(allocator, Registry.tools_list[1..]) catch return;
        body.appendSlice(allocator, "}") catch return;
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        appendToolCallResult(Registry, allocator, io, &body, scan, true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "server/discover")) {
        appendRpcResultRawMeta(allocator, &body, scan.id_raw, protocol.discoverResult(Registry), true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        appendListRpcResult(Registry, allocator, &body, scan.id_raw, "resources_list", true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        appendResourceReadRpc(Registry, allocator, io, &body, scan, true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        appendListRpcResult(Registry, allocator, &body, scan.id_raw, "prompts_list", true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        appendPromptGetRpc(Registry, allocator, io, &body, scan, true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "completion/complete")) {
        appendCompletionRpc(Registry, allocator, io, &body, scan, true);
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    } else if (std.mem.eql(u8, method, "subscriptions/listen")) {
        handleSubscriptionsListen(allocator, conn, scan, detached);
    } else {
        // Modern endpoint: unknown methods are 404 + -32601, distinguishable
        // from a legacy HTTP+SSE server's bare 404.
        appendRpcError(allocator, &body, scan.id_raw, -32601, "Method not found");
        respondJson(conn, "404 Not Found", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
    }
}

const ListenCtx = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    alloc: std.mem.Allocator,
};

/// Keep-alive for a subscriptions/listen SSE stream: an SSE comment line every
/// 15s (spec-encouraged) until the client disconnects — closing the stream is
/// itself the cancellation signal — then release the connection.
fn listenKeepAlive(ctx: *ListenCtx) void {
    defer {
        ctx.stream.close(ctx.io);
        ctx.alloc.destroy(ctx);
    }
    // Writer + buffer live on this thread's frame — safe after handleConnection returns.
    var buf: [64]u8 = undefined;
    var w = ctx.stream.writer(ctx.io, &buf);
    while (true) {
        std.Io.sleep(ctx.io, .fromSeconds(15), .awake) catch break;
        w.interface.writeAll(":\r\n") catch break;
        w.interface.flush() catch break;
    }
}

/// subscriptions/listen: the response is a long-lived SSE stream delivering
/// the opted-in change notifications. This server has no listChanged/update
/// sources, so after the initial result event only keep-alive comments flow —
/// trivially satisfying "MUST NOT send unrequested notification types".
fn handleSubscriptionsListen(
    allocator: std.mem.Allocator,
    conn: *Conn,
    scan: *const json.ScanResult,
    detached: *bool,
) void {
    const params_raw = scan.params_raw orelse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        appendRpcError(allocator, &body, scan.id_raw, -32602, "Missing params");
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
        return;
    };
    if (json.scanObj(params_raw, "notifications") == null) {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        appendRpcError(allocator, &body, scan.id_raw, -32602, "Missing notifications filter");
        respondJson(conn, "200 OK", body.items, null, protocol.MODERN_PROTOCOL_VERSION);
        return;
    }

    // SSE headers: indefinite (close-delimited) body, buffering disabled.
    conn.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nMcp-Protocol-Version: " ++ protocol.MODERN_PROTOCOL_VERSION ++ "\r\nAccess-Control-Allow-Origin: *\r\n\r\n");

    // Initial result event (SubscriptionsListenResult requires _meta + resultType).
    var ev: std.ArrayList(u8) = .empty;
    defer ev.deinit(allocator);
    ev.appendSlice(allocator, "data: {\"jsonrpc\":\"2.0\",\"id\":") catch return;
    ev.appendSlice(allocator, scan.id_raw orelse "null") catch return;
    ev.appendSlice(allocator, ",\"result\":{" ++ protocol.MODERN_RESULT_META ++ ",\"resultType\":\"complete\"}}\r\n\r\n") catch return;
    conn.writeAll(ev.items);
    conn.flush();

    // Hand the connection to a detached keep-alive thread; the accept loop
    // must NOT close the stream on return.
    const ctx = allocator.create(ListenCtx) catch return;
    ctx.* = .{ .io = conn.io, .stream = conn.stream, .alloc = allocator };
    const t = std.Thread.spawn(.{}, listenKeepAlive, .{ctx}) catch {
        allocator.destroy(ctx);
        return;
    };
    t.detach();
    detached.* = true;
}

// ── resources / prompts / completions (both modes) ─────────────────────────
//
// Optional registry decls (absent → -32601, matching advertised capabilities):
//   resources_list / prompts_list — '{"resources":[...]}' / '{"prompts":[...]}' fragments
//   readResourceFast(alloc, io, uri, out) bool — out = contents ARRAY fragment
//   getPromptFast(alloc, io, name, args_raw, out) bool — out = messages ARRAY fragment
//   completeFast(alloc, io, ref_raw, arg_name, arg_value, out) bool — out = completion OBJECT fragment

fn appendListRpcResult(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    comptime decl_name: []const u8,
    modern: bool,
) void {
    if (!@hasDecl(Registry, decl_name)) {
        appendRpcError(allocator, body, id_raw, -32601, "Method not found");
        return;
    }
    const fragment = @field(Registry, decl_name);
    if (!modern) {
        appendRpcResultRaw(allocator, body, id_raw, fragment);
        return;
    }
    // 2026-07-28 list results require resultType, ttlMs, cacheScope.
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":{" ++ protocol.MODERN_RESULT_META ++ ",\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"public\",") catch return;
    body.appendSlice(allocator, fragment[1..]) catch return;
    body.appendSlice(allocator, "}") catch return;
}

/// Shared builder for resources/read, prompts/get, completion/complete.
fn appendKeyedRpcResult(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    comptime key: []const u8,
    fragment: []const u8,
    comptime cacheable: bool,
    modern: bool,
) void {
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":{") catch return;
    if (modern) {
        body.appendSlice(allocator, protocol.MODERN_RESULT_META ++ ",") catch return;
        if (cacheable) {
            body.appendSlice(allocator, "\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"public\",") catch return;
        } else {
            body.appendSlice(allocator, "\"resultType\":\"complete\",") catch return;
        }
    }
    body.appendSlice(allocator, key) catch return;
    body.appendSlice(allocator, fragment) catch return;
    body.appendSlice(allocator, "}}") catch return;
}

fn appendResourceReadRpc(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *std.ArrayList(u8),
    scan: *const json.ScanResult,
    modern: bool,
) void {
    if (!@hasDecl(Registry, "readResourceFast")) {
        appendRpcError(allocator, body, scan.id_raw, -32601, "Method not found");
        return;
    }
    const params_raw = scan.params_raw orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing params");
        return;
    };
    const uri = json.scanStr(params_raw, "uri") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing uri");
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (!Registry.readResourceFast(allocator, io, uri, &out)) {
        appendRpcError(allocator, body, scan.id_raw, -32603, "Resource read failed");
        return;
    }
    appendKeyedRpcResult(allocator, body, scan.id_raw, "\"contents\":", out.items, true, modern);
}

fn appendPromptGetRpc(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *std.ArrayList(u8),
    scan: *const json.ScanResult,
    modern: bool,
) void {
    if (!@hasDecl(Registry, "getPromptFast")) {
        appendRpcError(allocator, body, scan.id_raw, -32601, "Method not found");
        return;
    }
    const params_raw = scan.params_raw orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing params");
        return;
    };
    const name = json.scanStr(params_raw, "name") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing name");
        return;
    };
    const args_raw = json.scanObj(params_raw, "arguments") orelse "{}";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (!Registry.getPromptFast(allocator, io, name, args_raw, &out)) {
        appendRpcError(allocator, body, scan.id_raw, -32603, "Prompt get failed");
        return;
    }
    appendKeyedRpcResult(allocator, body, scan.id_raw, "\"messages\":", out.items, false, modern);
}

fn appendCompletionRpc(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *std.ArrayList(u8),
    scan: *const json.ScanResult,
    modern: bool,
) void {
    if (!@hasDecl(Registry, "completeFast")) {
        appendRpcError(allocator, body, scan.id_raw, -32601, "Method not found");
        return;
    }
    const params_raw = scan.params_raw orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing params");
        return;
    };
    const ref_raw = json.scanObj(params_raw, "ref") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing ref");
        return;
    };
    const arg_raw = json.scanObj(params_raw, "argument") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing argument");
        return;
    };
    const arg_name = json.scanStr(arg_raw, "name") orelse "";
    const arg_value = json.scanStr(arg_raw, "value") orelse "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (!Registry.completeFast(allocator, io, ref_raw, arg_name, arg_value, &out)) {
        appendRpcError(allocator, body, scan.id_raw, -32603, "Completion failed");
        return;
    }
    appendKeyedRpcResult(allocator, body, scan.id_raw, "\"completion\":", out.items, false, modern);
}

fn appendToolCallResult(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *std.ArrayList(u8),
    scan: *const json.ScanResult,
    modern: bool,
) void {
    const params_raw = scan.params_raw orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing params");
        return;
    };
    const name = json.scanStr(params_raw, "name") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing tool name");
        return;
    };
    const args_raw = json.scanObj(params_raw, "arguments") orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Missing arguments");
        return;
    };
    const tool = Registry.parse(name) orelse {
        appendRpcError(allocator, body, scan.id_raw, -32602, "Unknown tool");
        return;
    };

    // MRTR (2026-07-28): registries may expose
    //   dispatchFastRaw(alloc, io, tool, args_raw, meta_raw, out) bool
    // to own the ENTIRE result object — including resultType:"inputRequired"
    // + inputRequests. params._meta (carrying inputResponses on follow-up
    // requests) is forwarded as meta_raw; correlation via the registry's own
    // requestState. The _meta serverInfo envelope is injected when modern.
    if (@hasDecl(Registry, "dispatchFastRaw")) {
        var raw_buf: std.ArrayList(u8) = .empty;
        defer raw_buf.deinit(allocator);
        _ = Registry.dispatchFastRaw(allocator, io, tool, args_raw, scan.meta_raw, &raw_buf);
        body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        body.appendSlice(allocator, scan.id_raw orelse "null") catch return;
        body.appendSlice(allocator, ",\"result\":") catch return;
        if (modern and raw_buf.items.len >= 2 and raw_buf.items[0] == '{') {
            body.appendSlice(allocator, "{" ++ protocol.MODERN_RESULT_META) catch return;
            if (raw_buf.items[1] == '}') {
                body.appendSlice(allocator, "}") catch return;
            } else {
                body.appendSlice(allocator, ",") catch return;
                body.appendSlice(allocator, raw_buf.items[1..]) catch return;
            }
        } else {
            body.appendSlice(allocator, raw_buf.items) catch return;
        }
        body.appendSlice(allocator, "}") catch return;
        return;
    }

    var tool_buf: std.ArrayList(u8) = .empty;
    defer tool_buf.deinit(allocator);
    const tool_ok = if (@hasDecl(Registry, "dispatchFastOk"))
        Registry.dispatchFastOk(allocator, io, tool, args_raw, &tool_buf)
    else blk: {
        Registry.dispatchFast(allocator, io, tool, args_raw, &tool_buf);
        break :blk true;
    };

    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, scan.id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(allocator, body, tool_buf.items);
    body.appendSlice(allocator, "\"}],\"isError\":") catch return;
    body.appendSlice(allocator, if (tool_ok) "false" else "true") catch return;
    if (tool_buf.items.len > 0 and tool_buf.items[0] == '{' and isValidJsonObject(tool_buf.items)) {
        body.appendSlice(allocator, ",\"structuredContent\":") catch return;
        body.appendSlice(allocator, tool_buf.items) catch return;
    }
    if (modern) {
        // 2026-07-28 CallToolResult requires resultType.
        body.appendSlice(allocator, ",\"resultType\":\"complete\"," ++ protocol.MODERN_RESULT_META) catch return;
    }
    body.appendSlice(allocator, "}}") catch return;
}

fn appendRpcResultRaw(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    result: []const u8,
) void {
    appendRpcResultRawMeta(allocator, body, id_raw, result, false);
}

/// `appendRpcResultRaw` + modern (2026-07-28) `_meta` serverInfo envelope:
/// when `stamp` is set and `result` is a JSON object, the envelope is injected
/// as the first result key (per ResultMetaObject).
fn appendRpcResultRawMeta(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    result: []const u8,
    stamp: bool,
) void {
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":") catch return;
    if (stamp and result.len >= 2 and result[0] == '{') {
        body.appendSlice(allocator, "{" ++ protocol.MODERN_RESULT_META) catch return;
        if (result[1] == '}') {
            body.appendSlice(allocator, "}") catch return;
        } else {
            body.appendSlice(allocator, ",") catch return;
            body.appendSlice(allocator, result[1..]) catch return;
        }
    } else {
        body.appendSlice(allocator, result) catch return;
    }
    body.appendSlice(allocator, "}") catch return;
}

/// 2026-07-28 UnsupportedProtocolVersionError: code -32022 with
/// `data: { requested, supported }`. HTTP transport MUST pair this with 400.
fn appendUnsupportedProtocolVersion(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    requested: []const u8,
) void {
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":\"") catch return;
    json.writeEscaped(allocator, body, requested);
    body.appendSlice(allocator, "\",\"supported\":" ++ protocol.SUPPORTED_VERSIONS_JSON ++ "}}}") catch return;
}

fn appendRpcError(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    code: i32,
    message: []const u8,
) void {
    var code_buf: [16]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch return;
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"error\":{\"code\":") catch return;
    body.appendSlice(allocator, code_str) catch return;
    body.appendSlice(allocator, ",\"message\":\"") catch return;
    json.writeEscaped(allocator, body, message);
    body.appendSlice(allocator, "\"}}") catch return;
}

fn respondJson(conn: *Conn, status: []const u8, body: []const u8, session_id: ?[]const u8, protocol_version: []const u8) void {
    var hdr_buf: [1024]u8 = undefined;
    const session_header = session_id orelse "";
    const hdr = if (session_id != null)
        std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nMcp-Protocol-Version: {s}\r\nMcp-Session-Id: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Accept, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\nAccess-Control-Expose-Headers: Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\n\r\n",
            .{ status, body.len, protocol_version, session_header },
        ) catch return
    else
        std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nMcp-Protocol-Version: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Accept, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\nAccess-Control-Expose-Headers: Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\n\r\n",
            .{ status, body.len, protocol_version },
        ) catch return;
    conn.writeAll(hdr);
    conn.writeAll(body);
    conn.flush();
}

fn respondEmpty(conn: *Conn, status: []const u8, session_id: ?[]const u8, protocol_version: []const u8) void {
    respondJson(conn, status, "", session_id, protocol_version);
}

/// Extract the bearer token from the Authorization header, if present.
fn bearerToken(req: Request) ?[]const u8 {
    const h = req.authorization orelse return null;
    if (h.len < 8 or !std.ascii.eqlIgnoreCase(h[0..7], "Bearer ")) return null;
    const t = std.mem.trim(u8, h[7..], " \t");
    return if (t.len == 0) null else t;
}

/// 401 + WWW-Authenticate challenge pointing at the metadata document (RFC 6750).
fn respondUnauthorized(conn: *Conn, opts: Options) void {
    var url_buf: [256]u8 = undefined;
    const meta_url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}/.well-known/oauth-protected-resource", .{ opts.host, opts.port }) catch return;
    const body = "{\"error\":\"unauthorized\"}";
    var hdr_buf: [1024]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nWWW-Authenticate: Bearer resource_metadata=\"{s}\"\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ body.len, meta_url },
    ) catch return;
    conn.writeAll(hdr);
    conn.writeAll(body);
    conn.flush();
}

/// RFC 9728 protected-resource metadata (public).
fn respondProtectedResourceMetadata(allocator: std.mem.Allocator, conn: *Conn, opts: Options, a: AuthConfig) void {
    var url_buf: [256]u8 = undefined;
    const resource_url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}/mcp", .{ opts.host, opts.port }) catch return;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    auth_mod.appendProtectedResourceMetadata(allocator, &body, resource_url, a.issuer);
    respondJson(conn, "200 OK", body.items, null, PROTOCOL_VERSION);
}

/// Legacy (2025-03-26..2025-11-25) GET listener: opens a real SSE stream for
/// the session. `Last-Event-ID` is parsed for the resume contract; this server
/// has no notification sources, so the event store is empty, every event id a
/// client could present replays zero events, and only keep-alive comments
/// flow. Client disconnect ends the stream (and, per 2025-era spec, may be
/// followed by DELETE to end the session).
fn respondSseListen(
    allocator: std.mem.Allocator,
    conn: *Conn,
    session_id: []const u8,
    protocol_version: []const u8,
    last_event_id: ?[]const u8,
    detached: *bool,
) void {
    _ = last_event_id; // replay buffer is empty — nothing to replay from any id
    var hdr_buf: [1024]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nMcp-Protocol-Version: {s}\r\nMcp-Session-Id: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Accept, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\nAccess-Control-Expose-Headers: Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\n\r\n",
        .{ protocol_version, session_id },
    ) catch return;
    conn.writeAll(hdr);
    conn.flush();

    // Hand the connection to a detached keep-alive thread (shared with the
    // 2026-07-28 subscriptions/listen path); the accept loop must NOT close it.
    const ctx = allocator.create(ListenCtx) catch return;
    ctx.* = .{ .io = conn.io, .stream = conn.stream, .alloc = allocator };
    const t = std.Thread.spawn(.{}, listenKeepAlive, .{ctx}) catch {
        allocator.destroy(ctx);
        return;
    };
    t.detach();
    detached.* = true;
}

fn parseRequest(raw: []const u8) ?Request {
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const line_raw = raw[0..line_end];
    const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r')
        line_raw[0 .. line_raw.len - 1]
    else
        line_raw;

    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const method = line[0..sp1];
    const target = rest[0..sp2];
    const qix = std.mem.indexOfScalar(u8, target, '?');
    const path = if (qix) |i| target[0..i] else target;

    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const headers = raw[0..header_end];
    const body = if (header_end + 4 <= raw.len) raw[header_end + 4 ..] else "";

    return .{
        .method = method,
        .path = path,
        .session_id = headerValue(headers, "Mcp-Session-Id"),
        .protocol_version = headerValue(headers, "Mcp-Protocol-Version"),
        .mcp_method = headerValue(headers, "Mcp-Method"),
        .mcp_name = headerValue(headers, "Mcp-Name"),
        .last_event_id = headerValue(headers, "Last-Event-ID"),
        .authorization = headerValue(headers, "Authorization"),
        .origin = headerValue(headers, "Origin"),
        .host = headerValue(headers, "Host"),
        .body = body,
    };
}

/// Spec security guidance: a browser-supplied Origin whose host does not match
/// the request's Host header indicates a cross-origin (DNS rebinding) attempt.
/// No Origin header means a non-browser client and is allowed.
fn originAllowed(req: Request) bool {
    const origin = req.origin orelse return true;
    const host = req.host orelse return true;
    // Strip scheme (and any trailing path) from the origin before comparing.
    var o = origin;
    if (std.mem.indexOf(u8, o, "://")) |i| o = o[i + 3 ..];
    if (std.mem.indexOfScalar(u8, o, '/')) |i| o = o[0..i];
    return std.ascii.eqlIgnoreCase(o, host);
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn findContentLength(headers: []const u8) usize {
    const raw = headerValue(headers, "Content-Length") orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

fn isValidJsonObject(data: []const u8) bool {
    if (data.len < 2 or data[0] != '{') return false;
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
        } else {
            switch (c) {
                '"' => in_string = true,
                '{' => depth += 1,
                '}' => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) return i == data.len - 1;
                },
                else => {},
            }
        }
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "headerValue: case-insensitive names, trimming, missing" {
    const testing = std.testing;
    const headers = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nmcp-session-id:  abc-123 \r\nX-Empty:\r\n";
    try testing.expectEqualStrings("application/json", headerValue(headers, "content-type").?);
    try testing.expectEqualStrings("abc-123", headerValue(headers, "Mcp-Session-Id").?);
    try testing.expectEqualStrings("", headerValue(headers, "x-empty").?);
    try testing.expect(headerValue(headers, "missing") == null);
}

test "parseRequest: method, path, headers, body, query strip" {
    const testing = std.testing;
    const raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: h:1\r\nMcp-Method: tools/list\r\nMcp-Name: read_file\r\nAuthorization: Bearer tok\r\nLast-Event-ID: 9\r\nContent-Length: 4\r\n\r\nbody";
    const req = parseRequest(raw).?;
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("/mcp", req.path);
    try testing.expectEqualStrings("h:1", req.host.?);
    try testing.expectEqualStrings("tools/list", req.mcp_method.?);
    try testing.expectEqualStrings("read_file", req.mcp_name.?);
    try testing.expectEqualStrings("Bearer tok", req.authorization.?);
    try testing.expectEqualStrings("9", req.last_event_id.?);
    try testing.expectEqualStrings("body", req.body);
    try testing.expect(parseRequest("garbage without spaces") == null);
}

test "originAllowed: browser vs non-browser clients" {
    const testing = std.testing;
    _ = testing;
    const base: Request = .{ .method = "POST", .path = "/mcp", .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = null, .origin = null, .host = null, .body = "" };
    // no Origin header (non-browser) → allow
    try std.testing.expect(originAllowed(base));
    // matching origin (scheme + optional port variations)
    try std.testing.expect(originAllowed(.{ .origin = "http://127.0.0.1:8000", .host = "127.0.0.1:8000", .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = null, .body = "" }));
    // mismatched origin → reject
    try std.testing.expect(!originAllowed(.{ .origin = "https://evil.example.com", .host = "127.0.0.1:8000", .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = null, .body = "" }));
    // origin with trailing path still compares host part
    try std.testing.expect(originAllowed(.{ .origin = "http://127.0.0.1:8000/some/path", .host = "127.0.0.1:8000", .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = null, .body = "" }));
}

test "bearerToken extraction" {
    const testing = std.testing;
    _ = testing;
    const base: Request = .{ .method = "POST", .path = "/mcp", .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = null, .origin = null, .host = null, .body = "" };
    try std.testing.expect(bearerToken(base) == null);
    const with_tok: Request = .{ .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = "Bearer abc.def.ghi", .origin = null, .host = null, .body = "" };
    try std.testing.expectEqualStrings("abc.def.ghi", bearerToken(with_tok).?);
    const wrong_scheme: Request = .{ .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = "Basic abc", .origin = null, .host = null, .body = "" };
    try std.testing.expect(bearerToken(wrong_scheme) == null);
    const empty_tok: Request = .{ .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = "Bearer  ", .origin = null, .host = null, .body = "" };
    try std.testing.expect(bearerToken(empty_tok) == null);
    // case-insensitive scheme
    const lower: Request = .{ .method = base.method, .path = base.path, .session_id = null, .protocol_version = null, .mcp_method = null, .mcp_name = null, .last_event_id = null, .authorization = "bearer xyz", .origin = null, .host = null, .body = "" };
    try std.testing.expectEqualStrings("xyz", bearerToken(lower).?);
}

test "SessionStore create/getVersion/remove" {
    const testing = std.testing;
    var store = SessionStore.init(testing.allocator);
    defer store.deinit();
    const id = try store.create("2025-06-18");
    try testing.expectEqualStrings("2025-06-18", store.getVersion(id).?);
    try testing.expect(store.getVersion("nope") == null);
    try testing.expect(store.remove(id));
    try testing.expect(store.getVersion(id) == null);
    try testing.expect(!store.remove(id));
}

test "appendRpcResultRawMeta injects _meta only for objects" {
    const testing = std.testing;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);

    appendRpcResultRawMeta(testing.allocator, &body, "1", "{\"tools\":[]}", true);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"result\":{\"_meta\":{\"io.modelcontextprotocol/serverInfo\":") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, ",\"tools\":[]}") != null);

    body.clearRetainingCapacity();
    appendRpcResultRawMeta(testing.allocator, &body, "2", "{}", true);
    try testing.expect(std.mem.indexOf(u8, body.items, "{\"_meta\":{\"io.modelcontextprotocol/serverInfo\":") != null);
    // empty object: no trailing comma garbage
    try testing.expect(std.mem.indexOf(u8, body.items, ",}") == null);

    body.clearRetainingCapacity();
    appendRpcResultRawMeta(testing.allocator, &body, "3", "{\"tools\":[]}", false);
    try testing.expect(std.mem.indexOf(u8, body.items, "_meta") == null);
}

test "appendUnsupportedProtocolVersion and appendHeaderMismatch shapes" {
    const testing = std.testing;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    appendUnsupportedProtocolVersion(testing.allocator, &body, "7", "2099-01-01");
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32022") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"requested\":\"2099-01-01\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"2026-07-28\"") != null); // supported list

    body.clearRetainingCapacity();
    appendHeaderMismatch(testing.allocator, &body, "8", "missing Mcp-Method header");
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32020") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, "missing Mcp-Method header") != null);
}

const mock_http_registry = struct {
    pub const tools_list = "{\"tools\":[]}";
    pub fn parse(name: []const u8) ?u0 {
        _ = name;
        return null;
    }
    pub fn dispatchFast(alloc: std.mem.Allocator, io: std.Io, tool: u0, args_raw: []const u8, out: *std.ArrayList(u8)) void {
        _ = alloc;
        _ = io;
        _ = tool;
        _ = args_raw;
        _ = out;
    }
    pub const resources_list = "{\"resources\":[{\"uri\":\"file:///a\"}]}";
    pub fn readResourceFast(alloc: std.mem.Allocator, io: std.Io, uri: []const u8, out: *std.ArrayList(u8)) bool {
        _ = io;
        if (!std.mem.eql(u8, uri, "file:///a")) return false;
        out.appendSlice(alloc, "[{\"uri\":\"file:///a\",\"text\":\"A\"}]") catch return false;
        return true;
    }
};

test "appendListRpcResult: modern wrap, legacy raw, missing decl" {
    const testing = std.testing;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);

    // modern: meta + resultType + ttlMs + cacheScope
    appendListRpcResult(mock_http_registry, testing.allocator, &body, "1", "resources_list", true);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"resultType\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"ttlMs\":300000") != null);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"resources\":[{\"uri\":\"file:///a\"}]") != null);

    // legacy: raw fragment, no extras
    body.clearRetainingCapacity();
    appendListRpcResult(mock_http_registry, testing.allocator, &body, "2", "resources_list", false);
    try testing.expect(std.mem.indexOf(u8, body.items, "resultType") == null);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"result\":{\"resources\":") != null);

    // missing decl → -32601
    body.clearRetainingCapacity();
    appendListRpcResult(mock_http_registry, testing.allocator, &body, "3", "prompts_list", true);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32601") != null);
}

test "appendResourceReadRpc: success, missing uri, handler failure, absent decl" {
    const testing = std.testing;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);

    const ok_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///a\"}}";
    var scan = json.scanJsonRpc(ok_req);
    appendResourceReadRpc(mock_http_registry, testing.allocator, undefined, &body, &scan, false);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"contents\":[{\"uri\":\"file:///a\",\"text\":\"A\"}]") != null);

    // missing uri
    body.clearRetainingCapacity();
    const no_uri = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{}}";
    scan = json.scanJsonRpc(no_uri);
    appendResourceReadRpc(mock_http_registry, testing.allocator, undefined, &body, &scan, false);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32602") != null);

    // handler failure → -32603
    body.clearRetainingCapacity();
    const bad_uri = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///nope\"}}";
    scan = json.scanJsonRpc(bad_uri);
    appendResourceReadRpc(mock_http_registry, testing.allocator, undefined, &body, &scan, false);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32603") != null);

    // registry without the decl → -32601
    body.clearRetainingCapacity();
    scan = json.scanJsonRpc(ok_req);
    appendResourceReadRpc(mock_rpc_minimal, testing.allocator, undefined, &body, &scan, false);
    try testing.expect(std.mem.indexOf(u8, body.items, "\"code\":-32601") != null);
}

const mock_rpc_minimal = struct {
    pub const tools_list = "{\"tools\":[]}";
    pub fn parse(name: []const u8) ?u0 {
        _ = name;
        return null;
    }
    pub fn dispatchFast(alloc: std.mem.Allocator, io: std.Io, tool: u0, args_raw: []const u8, out: *std.ArrayList(u8)) void {
        _ = alloc;
        _ = io;
        _ = tool;
        _ = args_raw;
        _ = out;
    }
};
