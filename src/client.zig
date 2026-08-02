// mcp-zig — MCP client (JSON-RPC 2.0 over stdio to a child process)
//
// Spawns an MCP server as a child process and communicates via stdin/stdout.
// Handles the full lifecycle: initialize → tools/list → tools/call → exit.
//
// Protocol version: 2025-06-18
// Handles server-to-client requests (e.g. roots/list) that may arrive
// interleaved between the client's own request/response pairs.
//
// Usage:
//   var client = try McpClient.init(alloc, io, &.{"/path/to/server"}, null);
//   defer client.deinit();
//   try client.initialize();
//   const tools = try client.listTools();
//   const result = try client.callTool("read_file", "{\"path\":\"hello.txt\"}");

const std = @import("std");
const json = @import("json.zig");

pub const McpClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    process: std.process.Child,
    next_id: i64,
    stdout_reader: std.Io.File.Reader,
    stdout_buffer: []u8,
    line_buf: std.ArrayList(u8) = .empty,

    /// Modern (2026-07-28) mode: when set, every request self-describes via
    /// params._meta (protocolVersion + clientInfo + clientCapabilities) and no
    /// initialize handshake is needed. Null = legacy handshake mode.
    modern: ?ModernIdentity = null,

    pub const ModernIdentity = struct {
        name: []const u8,
        version: []const u8,
        protocol_version: []const u8 = "2026-07-28",
    };

    /// Opt into modern (2026-07-28) stateless mode: skip initialize entirely
    /// and stamp every request with _meta.
    pub fn useModern(self: *McpClient, identity: ModernIdentity) void {
        self.modern = identity;
    }

    /// Append `"_meta":{...}` (no leading comma) for modern requests.
    fn appendModernMeta(self: *McpClient, buf: *std.ArrayList(u8)) void {
        const id = self.modern orelse return;
        buf.appendSlice(self.alloc, "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"") catch return;
        buf.appendSlice(self.alloc, id.protocol_version) catch return;
        buf.appendSlice(self.alloc, "\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"") catch return;
        json.writeEscaped(self.alloc, buf, id.name);
        buf.appendSlice(self.alloc, "\",\"version\":\"") catch return;
        json.writeEscaped(self.alloc, buf, id.version);
        buf.appendSlice(self.alloc, "\"},\"io.modelcontextprotocol/clientCapabilities\":{}}") catch return;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        cwd: ?[]const u8,
    ) !McpClient {
        const stdout_buffer = try alloc.alloc(u8, 4096);
        errdefer alloc.free(stdout_buffer);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |d| .{ .path = d } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        return .{
            .alloc = alloc,
            .io = io,
            .process = child,
            .next_id = 1,
            .stdout_reader = child.stdout.?.readerStreaming(io, stdout_buffer),
            .stdout_buffer = stdout_buffer,
        };
    }

    pub fn deinit(self: *McpClient) void {
        // Close stdin first to signal the server to exit, then wait.
        // Don't close stdout/stderr manually — process.wait() handles cleanup.
        if (self.process.stdin) |stdin| {
            stdin.close(self.io);
            self.process.stdin = null;
        }
        if (self.process.id != null) _ = self.process.wait(self.io) catch {};
        self.line_buf.deinit(self.alloc);
        self.alloc.free(self.stdout_buffer);
    }

    // ── High-level API ──────────────────────────────────────────────────────

    /// Send initialize and wait for response. Returns server info as raw JSON string.
    pub fn initialize(self: *McpClient) ![]u8 {
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"mcp-zig-client","version":"1.0.0"}}}
        ;
        return self.sendAndReceive(req);
    }

    /// Send notifications/initialized (no response expected).
    pub fn notifyInitialized(self: *McpClient) !void {
        const msg = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        const stdin = self.process.stdin orelse return error.StdinClosed;
        try stdin.writeStreamingAll(self.io, msg);
    }

    /// List available tools. Returns raw JSON result string.
    pub fn listTools(self: *McpClient) ![]u8 {
        if (self.modern != null) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.alloc);
            var id_buf: [20]u8 = undefined;
            const id = self.next_id;
            self.next_id += 1;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, ",\"method\":\"tools/list\",\"params\":{") catch return error.OutOfMemory;
            self.appendModernMeta(&buf);
            buf.appendSlice(self.alloc, "}}\n") catch return error.OutOfMemory;
            const stdin = self.process.stdin orelse return error.StdinClosed;
            try stdin.writeStreamingAll(self.io, buf.items);
            return self.readResponse();
        }
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"tools/list","params":{}}
        ;
        return self.sendAndReceive(req);
    }

    /// 2026-07-28: stateless discovery — the modern replacement for
    /// initialize's version negotiation. Works in either mode.
    pub fn discover(self: *McpClient) ![]u8 {
        if (self.modern != null) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.alloc);
            var id_buf: [20]u8 = undefined;
            const id = self.next_id;
            self.next_id += 1;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, ",\"method\":\"server/discover\",\"params\":{") catch return error.OutOfMemory;
            self.appendModernMeta(&buf);
            buf.appendSlice(self.alloc, "}}\n") catch return error.OutOfMemory;
            const stdin = self.process.stdin orelse return error.StdinClosed;
            try stdin.writeStreamingAll(self.io, buf.items);
            return self.readResponse();
        }
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"server/discover","params":{}}
        ;
        return self.sendAndReceive(req);
    }

    /// Call a tool by name with JSON arguments string. Returns the tool result text.
    pub fn callTool(self: *McpClient, name: []const u8, args_json: []const u8) ![]u8 {
        // Build request manually to avoid dynamic JSON construction overhead
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        // Pre-allocate: base template ~70 + name + args + id + margin
        buf.ensureTotalCapacity(self.alloc, 80 + name.len + args_json.len) catch {};
        buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        var id_buf: [20]u8 = undefined;
        const id = self.next_id;
        self.next_id += 1;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, ",\"method\":\"tools/call\",\"params\":{\"name\":\"") catch return error.OutOfMemory;
        json.writeEscaped(self.alloc, &buf, name);
        buf.appendSlice(self.alloc, "\",\"arguments\":") catch return error.OutOfMemory;
        buf.appendSlice(self.alloc, args_json) catch return error.OutOfMemory;
        if (self.modern != null) {
            buf.appendSlice(self.alloc, ",") catch return error.OutOfMemory;
            self.appendModernMeta(&buf);
        }
        buf.appendSlice(self.alloc, "}}\n") catch return error.OutOfMemory;

        const stdin = self.process.stdin orelse return error.StdinClosed;
        try stdin.writeStreamingAll(self.io, buf.items);

        return self.readResponse();
    }

    /// Send a ping and wait for pong. Returns true if server responds.
    pub fn ping(self: *McpClient) !bool {
        const result = self.sendAndReceive(
            \\{"jsonrpc":"2.0","id":__ID__,"method":"ping","params":{}}
        ) catch return false;
        self.alloc.free(result);
        return true;
    }

    // ── Low-level helpers ────────────────────────────────────────────────────

    fn sendAndReceive(self: *McpClient, template: []const u8) ![]u8 {
        // Replace __ID__ with actual ID using indexOf for O(1) find
        const id = self.next_id;
        self.next_id += 1;
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        buf.ensureTotalCapacity(self.alloc, template.len + id_str.len) catch {};

        if (std.mem.indexOf(u8, template, "__ID__")) |pos| {
            buf.appendSlice(self.alloc, template[0..pos]) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, id_str) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, template[pos + 6 ..]) catch return error.OutOfMemory;
        } else {
            buf.appendSlice(self.alloc, template) catch return error.OutOfMemory;
        }
        buf.append(self.alloc, '\n') catch return error.OutOfMemory;

        const stdin = self.process.stdin orelse return error.StdinClosed;
        try stdin.writeStreamingAll(self.io, buf.items);

        return self.readResponse();
    }

    /// Read the next JSON-RPC response from the server.
    /// Transparently handles interleaved server-to-client requests (e.g. roots/list)
    /// by responding to them and continuing to read until a response arrives.
    fn readResponse(self: *McpClient) ![]u8 {
        while (true) {
            const line = try self.readOneLine();

            // Check if this is a server-to-client request (has "method", no "result")
            // If so, respond and keep reading for our actual response.
            if (self.handleServerRequest(line)) {
                self.alloc.free(line);
                continue;
            }

            return line;
        }
    }

    /// Read exactly one newline-terminated line from the server's stdout.
    fn readOneLine(self: *McpClient) ![]u8 {
        const line = json.readLineInto(self.alloc, &self.stdout_reader.interface, &self.line_buf) orelse
            return error.ServerClosed;
        if (line.len > json.MAX_LINE) return error.ResponseTooLarge;
        return self.alloc.dupe(u8, line);
    }

    /// If `line` is a server-to-client request (has "method" field), respond and return true.
    /// Returns false for normal responses — caller should return the line as-is.
    fn handleServerRequest(self: *McpClient, line: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch return false;
        defer parsed.deinit();

        if (parsed.value != .object) return false;
        const obj = &parsed.value.object;

        // Responses have "result" or "error" but no "method"
        const method = json.getStr(obj, "method") orelse return false;
        const id = obj.get("id");

        if (json.eql(method, "roots/list")) {
            // Respond with workspace roots (cwd by default)
            self.respondRoots(id);
        } else {
            // Unknown server request — send method-not-found error
            self.respondError(id, -32601, "Method not found");
        }
        return true;
    }

    /// Respond to a roots/list request with the client's workspace roots.
    /// By default, reports the current working directory.
    fn respondRoots(self: *McpClient, id: ?std.json.Value) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        appendId(self.alloc, &buf, id);
        buf.appendSlice(self.alloc, ",\"result\":{\"roots\":[{\"uri\":\"file://") catch return;

        // Use cwd as the default root
        const cwd = std.process.currentPathAlloc(self.io, self.alloc) catch {
            // Fallback: empty roots
            buf.clearRetainingCapacity();
            buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
            appendId(self.alloc, &buf, id);
            buf.appendSlice(self.alloc, ",\"result\":{\"roots\":[]}}\n") catch return;
            const stdin = self.process.stdin orelse return;
            stdin.writeStreamingAll(self.io, buf.items) catch {};
            return;
        };
        defer self.alloc.free(cwd);
        json.writeEscaped(self.alloc, &buf, cwd);
        buf.appendSlice(self.alloc, "\",\"name\":\"workspace\"}]}}\n") catch return;

        const stdin = self.process.stdin orelse return;
        stdin.writeStreamingAll(self.io, buf.items) catch {};
    }

    /// Send a JSON-RPC error response to the server.
    fn respondError(self: *McpClient, id: ?std.json.Value, code: i32, msg: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        appendId(self.alloc, &buf, id);
        buf.appendSlice(self.alloc, ",\"error\":{\"code\":") catch return;
        var tmp: [12]u8 = undefined;
        const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
        buf.appendSlice(self.alloc, cs) catch return;
        buf.appendSlice(self.alloc, ",\"message\":\"") catch return;
        json.writeEscaped(self.alloc, &buf, msg);
        buf.appendSlice(self.alloc, "\"}}\n") catch return;

        const stdin = self.process.stdin orelse return;
        stdin.writeStreamingAll(self.io, buf.items) catch {};
    }

    fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
        if (id) |v| switch (v) {
            .integer => |n| {
                var tmp: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
                buf.appendSlice(alloc, s) catch return;
            },
            .string => |s| {
                buf.append(alloc, '"') catch return;
                json.writeEscaped(alloc, buf, s);
                buf.append(alloc, '"') catch return;
            },
            else => buf.appendSlice(alloc, "null") catch return,
        } else {
            buf.appendSlice(alloc, "null") catch return;
        }
    }
};

// ── Convenience: run a one-shot tool call ────────────────────────────────────

/// Spawn server, initialize, call one tool, return result, clean up.
/// Convenience for scripts that just need a single tool call.
pub fn callOnce(
    alloc: std.mem.Allocator,
    io: std.Io,
    server_argv: []const []const u8,
    tool_name: []const u8,
    args_json: []const u8,
) ![]u8 {
    var client = try McpClient.init(alloc, io, server_argv, null);
    defer client.deinit();

    const init_result = try client.initialize();
    alloc.free(init_result);
    try client.notifyInitialized();

    return client.callTool(tool_name, args_json);
}

// ── HTTP client (modern 2026-07-28 Streamable HTTP) ─────────────────────────
//
// Stateless client for the HTTP transport: every call is one POST with the
// mirrored metadata headers (MCP-Protocol-Version, Mcp-Method, Mcp-Name).
// http:// only (localhost/LAN) — TLS termination is left to a proxy. Legacy
// session-mode HTTP is intentionally not implemented (use modern servers).
//
//   var c = try mcp.client.HttpClient.init(alloc, io, "127.0.0.1:8000");
//   c.useModern(.{ .name = "my-client", .version = "1.0" });
//   const tools = try c.listTools();

pub const HttpClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    next_id: i64 = 1,
    modern: ?McpClient.ModernIdentity = null,
    bearer_token: ?[]const u8 = null,

    /// `endpoint` is "host:port" or "http://host:port".
    pub fn init(alloc: std.mem.Allocator, io: std.Io, endpoint: []const u8) !HttpClient {
        var e = endpoint;
        if (std.mem.startsWith(u8, e, "http://")) e = e[7..];
        if (std.mem.endsWith(u8, e, "/")) e = e[0 .. e.len - 1];
        const colon = std.mem.lastIndexOfScalar(u8, e, ':') orelse return error.InvalidEndpoint;
        const host = e[0..colon];
        if (std.mem.eql(u8, host, "localhost")) {
            return .{ .alloc = alloc, .io = io, .host = "127.0.0.1", .port = try std.fmt.parseInt(u16, e[colon + 1 ..], 10) };
        }
        return .{ .alloc = alloc, .io = io, .host = host, .port = try std.fmt.parseInt(u16, e[colon + 1 ..], 10) };
    }

    /// Stamp every request with _meta (protocolVersion/clientInfo/caps).
    pub fn useModern(self: *HttpClient, identity: McpClient.ModernIdentity) void {
        self.modern = identity;
    }

    /// Bearer token for servers with authorization enabled.
    pub fn setBearer(self: *HttpClient, token: []const u8) void {
        self.bearer_token = token;
    }

    /// server/discover.
    pub fn discover(self: *HttpClient) ![]u8 {
        return self.call("server/discover", null, "{}");
    }

    pub fn listTools(self: *HttpClient) ![]u8 {
        return self.call("tools/list", null, "{}");
    }

    pub fn callTool(self: *HttpClient, name: []const u8, args_json: []const u8) ![]u8 {
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.alloc);
        params.appendSlice(self.alloc, "{\"name\":\"") catch return error.OutOfMemory;
        json.writeEscaped(self.alloc, &params, name);
        params.appendSlice(self.alloc, "\",\"arguments\":") catch return error.OutOfMemory;
        params.appendSlice(self.alloc, args_json) catch return error.OutOfMemory;
        params.appendSlice(self.alloc, "}") catch return error.OutOfMemory;
        return self.call("tools/call", name, params.items);
    }

    /// One stateless JSON-RPC POST. `mcp_name` is required for tools/call.
    pub fn call(self: *HttpClient, method: []const u8, mcp_name: ?[]const u8, params_json: []const u8) ![]u8 {
        const alloc = self.alloc;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var id_buf: [20]u8 = undefined;
        const id = self.next_id;
        self.next_id += 1;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
        body.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        body.appendSlice(alloc, id_str) catch return error.OutOfMemory;
        body.appendSlice(alloc, ",\"method\":\"") catch return error.OutOfMemory;
        body.appendSlice(alloc, method) catch return error.OutOfMemory;
        body.appendSlice(alloc, "\",\"params\":") catch return error.OutOfMemory;
        // splice _meta into the params object when modern
        if (self.modern) |mid| {
            if (params_json.len >= 2 and params_json[0] == '{') {
                body.appendSlice(alloc, "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"") catch return error.OutOfMemory;
                body.appendSlice(alloc, mid.protocol_version) catch return error.OutOfMemory;
                body.appendSlice(alloc, "\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"") catch return error.OutOfMemory;
                json.writeEscaped(alloc, &body, mid.name);
                body.appendSlice(alloc, "\",\"version\":\"") catch return error.OutOfMemory;
                json.writeEscaped(alloc, &body, mid.version);
                body.appendSlice(alloc, "\"},\"io.modelcontextprotocol/clientCapabilities\":{}}") catch return error.OutOfMemory;
                if (params_json[1] != '}') {
                    body.appendSlice(alloc, ",") catch return error.OutOfMemory;
                    body.appendSlice(alloc, params_json[1..]) catch return error.OutOfMemory;
                } else {
                    body.appendSlice(alloc, "}") catch return error.OutOfMemory;
                }
            } else {
                body.appendSlice(alloc, params_json) catch return error.OutOfMemory;
            }
        } else {
            body.appendSlice(alloc, params_json) catch return error.OutOfMemory;
        }
        body.appendSlice(alloc, "}") catch return error.OutOfMemory;

        // headers
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(alloc);
        hdr.print(alloc, "POST /mcp HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ self.host, self.port, body.items.len }) catch return error.OutOfMemory;
        if (self.modern) |mid| {
            hdr.print(alloc, "MCP-Protocol-Version: {s}\r\nMcp-Method: {s}\r\n", .{ mid.protocol_version, method }) catch return error.OutOfMemory;
            if (mcp_name) |n| hdr.print(alloc, "Mcp-Name: {s}\r\n", .{n}) catch return error.OutOfMemory;
        }
        if (self.bearer_token) |t| hdr.print(alloc, "Authorization: Bearer {s}\r\n", .{t}) catch return error.OutOfMemory;
        hdr.appendSlice(alloc, "\r\n") catch return error.OutOfMemory;

        // connect + send + read-until-close
        const addr = try std.Io.net.IpAddress.parse(self.host, self.port);
        var stream = try addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(self.io);
        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(hdr.items);
        try w.interface.writeAll(body.items);
        try w.interface.flush();

        var resp: std.ArrayList(u8) = .empty;
        errdefer resp.deinit(alloc);
        var rbuf: [8192]u8 = undefined;
        while (true) {
            var iov: [1][]u8 = .{&rbuf};
            const n = stream.read(self.io, &iov) catch break;
            if (n == 0) break;
            resp.appendSlice(alloc, rbuf[0..n]) catch return error.OutOfMemory;
            if (resp.items.len > 4 * 1024 * 1024) return error.ResponseTooLarge;
        }

        // status check + body extraction
        const status_ok = std.mem.indexOf(u8, resp.items, " 200 ") != null;
        const split = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse return error.BadResponse;
        const resp_body = resp.items[split + 4 ..];
        if (!status_ok) {
            std.log.err("mcp HTTP call failed: {s}", .{resp.items[0..@min(split, 200)]});
            return error.RequestFailed;
        }
        const out = try alloc.dupe(u8, resp_body);
        resp.deinit(alloc);
        return out;
    }
};
