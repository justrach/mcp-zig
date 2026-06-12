// mcp-zig — Streamable HTTP transport, phase 1.
//
// This serves MCP JSON-RPC over POST /mcp. It deliberately keeps stdio
// unchanged and reuses the existing tool registry/dispatch path.

const std = @import("std");
const json = @import("json.zig");
const protocol = @import("mcp.zig");
const default_tools = @import("tools.zig");

const PROTOCOL_VERSION = protocol.PROTOCOL_VERSION;

const MAX_REQUEST_BYTES = 1024 * 1024;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8000,
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
        handleConnection(Registry, io, allocator, stream, &sessions);
        stream.close(io);
    }
}

fn readSome(io: std.Io, stream: std.Io.net.Stream, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    var iov: [1][]u8 = .{dest};
    return try io.vtable.netRead(io.userdata, stream.socket.handle, &iov);
}

fn handleConnection(
    comptime Registry: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    sessions: *SessionStore,
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

    if (!std.mem.eql(u8, req.path, "/mcp")) {
        respondJson(&conn, "404 Not Found", "{\"error\":\"not found\"}", null, PROTOCOL_VERSION);
        return;
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
        respondSseUnavailable(&conn, session_id, protocol_version);
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

    handlePost(Registry, allocator, io, &conn, sessions, req);
}

fn handlePost(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: *Conn,
    sessions: *SessionStore,
    req: Request,
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

    if (std.mem.eql(u8, method, "initialize")) {
        const requested_version = if (scan.params_raw) |params_raw|
            json.scanStr(params_raw, "protocolVersion")
        else
            null;
        const negotiated = protocol.negotiateProtocolVersion(requested_version);
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
    }

    if (scan.id_raw == null) {
        respondEmpty(conn, "202 Accepted", session_id, protocol_version);
        return;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    if (std.mem.eql(u8, method, "ping")) {
        appendRpcResultRaw(allocator, &body, scan.id_raw, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        appendRpcResultRaw(allocator, &body, scan.id_raw, Registry.tools_list);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        appendToolCallResult(Registry, allocator, io, &body, &scan);
    } else if (std.mem.eql(u8, method, "logging/setLevel")) {
        appendRpcResultRaw(allocator, &body, scan.id_raw, "{}");
    } else {
        appendRpcError(allocator, &body, scan.id_raw, -32601, "Method not found");
    }

    respondJson(conn, "200 OK", body.items, session_id, protocol_version);
}

fn appendToolCallResult(
    comptime Registry: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *std.ArrayList(u8),
    scan: *const json.ScanResult,
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

    var tool_buf: std.ArrayList(u8) = .empty;
    defer tool_buf.deinit(allocator);
    Registry.dispatchFast(allocator, io, tool, args_raw, &tool_buf);

    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, scan.id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(allocator, body, tool_buf.items);
    body.appendSlice(allocator, "\"}],\"isError\":false") catch return;
    if (tool_buf.items.len > 0 and tool_buf.items[0] == '{' and isValidJsonObject(tool_buf.items)) {
        body.appendSlice(allocator, ",\"structuredContent\":") catch return;
        body.appendSlice(allocator, tool_buf.items) catch return;
    }
    body.appendSlice(allocator, "}}") catch return;
}

fn appendRpcResultRaw(
    allocator: std.mem.Allocator,
    body: *std.ArrayList(u8),
    id_raw: ?[]const u8,
    result: []const u8,
) void {
    body.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    body.appendSlice(allocator, id_raw orelse "null") catch return;
    body.appendSlice(allocator, ",\"result\":") catch return;
    body.appendSlice(allocator, result) catch return;
    body.appendSlice(allocator, "}") catch return;
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

fn respondSseUnavailable(conn: *Conn, session_id: []const u8, protocol_version: []const u8) void {
    const body = "event: mcp-zig\r\ndata: {\"status\":\"sse-not-implemented\",\"message\":\"POST request/response JSON-RPC is available; resumable SSE is future work.\"}\r\n\r\n";
    var hdr_buf: [1024]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\nMcp-Protocol-Version: {s}\r\nMcp-Session-Id: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Accept, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\nAccess-Control-Expose-Headers: Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID\r\n\r\n",
        .{ body.len, protocol_version, session_id },
    ) catch return;
    conn.writeAll(hdr);
    conn.writeAll(body);
    conn.flush();
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
        .body = body,
    };
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
