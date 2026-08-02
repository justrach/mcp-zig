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

// ── HTTP client (2026-07-28 Streamable HTTP, TLS-capable) ───────────────────
//
// Built on std.http.Client (TLS, redirects-off, connection pooling) with the
// patterns proven in codegraff's mcp_http.zig:
//   - https anywhere; http only for localhost (validRemoteUrl policy)
//   - SSE (text/event-stream) response parsing, per spec clients MUST accept both
//   - hard request deadline via Io.Select racing (connection poisoned on timeout)
//   - Mcp-Name base64 sentinel encoding for header-unsafe tool names
//   - probe()/classifyProbe for automatic modern-vs-legacy detection
//
//   var c = try mcp.client.HttpClient.init(alloc, io, "https://mcp.example.com/mcp");
//   defer c.deinit();
//   switch (try c.probe()) { .modern => c.useModern(.{ .name = "app", .version = "1" }), .legacy => {}, else => return }
//   const tools = try c.listTools();

const protocol = @import("mcp.zig");

const max_http_response = 1 << 20;

/// https is always allowed; plain http only for loopback (DNS-rebinding and
/// plaintext-interception hygiene, same rule codegraff enforces).
pub fn validRemoteUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.host == null) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host = uri.host.?.percent_encoded;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1");
}

/// The three error codes introduced by 2026-07-28. Only these are ever read
/// as "this server speaks the modern protocol" (the -32000..-32019 range is
/// grandfathered implementation-defined and means something else on legacy).
pub const ModernError = enum { header_mismatch, missing_capability, unsupported_version };

pub fn modernErrorCode(code: i64) ?ModernError {
    return switch (code) {
        -32020 => .header_mismatch,
        -32021 => .missing_capability,
        -32022 => .unsupported_version,
        else => null,
    };
}

/// Outcome of probing a server for its protocol era.
pub const Probe = enum { modern, legacy, unsupported_version, incompatible };

/// Classify a probe reply body. An unparseable body is exactly what a legacy
/// server produces for a method it never heard of, so it reads as .legacy.
/// Scanner-based (no JSON tree), so it can never crash on garbage.
pub fn classifyProbe(raw_body: []const u8) Probe {
    const trimmed = std.mem.trim(u8, raw_body, " \t\r\n");
    if (trimmed.len == 0) return .legacy;
    // scanInt/scanStr are single-level — descend into the error object first.
    const err_obj = json.scanObj(trimmed, "error") orelse return .legacy;
    const code = json.scanInt(err_obj, "code") orelse return .legacy;
    const kind = modernErrorCode(code) orelse return .legacy;
    return switch (kind) {
        .header_mismatch, .missing_capability => .modern,
        .unsupported_version => blk: {
            // data.supported overlapping anything we speak?
            if (std.mem.indexOf(u8, trimmed, protocol.MODERN_PROTOCOL_VERSION) != null) break :blk .unsupported_version;
            for (protocol.SUPPORTED_PROTOCOL_VERSIONS) |v| {
                if (std.mem.indexOf(u8, trimmed, v) != null) break :blk .unsupported_version;
            }
            break :blk .incompatible;
        },
    };
}

fn looksLikeSentinel(value: []const u8) bool {
    return value.len >= 4 and std.mem.startsWith(u8, value, "=?") and std.mem.endsWith(u8, value, "?=");
}

fn isHeaderSafe(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value[0] == ' ' or value[0] == '\t') return false;
    for (value) |c| {
        if (!(c == 0x20 or c == 0x09 or (c >= 0x21 and c <= 0x7E))) return false;
    }
    return !looksLikeSentinel(value);
}

/// Encode an `Mcp-Name` (or similar MCP header) value per the spec: plain if
/// every byte is header-safe and it isn't already sentinel-shaped; otherwise
/// the whole value is base64'd inside `=?base64?<b64>?=` so non-ASCII or
/// newline-bearing names can't corrupt the header line.
pub fn headerValueEncoded(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isHeaderSafe(value)) return alloc.dupe(u8, value);
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(value.len));
    defer alloc.free(out);
    const encoded = enc.encode(out, value);
    return std.fmt.allocPrint(alloc, "=?base64?{s}?=", .{encoded});
}

/// Read an SSE response stream, returning the first complete `data:` event
/// (multi-line data joined with newlines; blank line terminates an event).
/// Bounded by max_http_response. Ported from codegraff's readSseResponse.
fn readSseResponse(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    const line_buf = try gpa.alloc(u8, max_http_response);
    defer gpa.free(line_buf);
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(gpa);
    var consumed: usize = 0;

    while (consumed < max_http_response) {
        var line_writer = std.Io.Writer.fixed(line_buf);
        const remaining = max_http_response - consumed;
        const n = reader.streamDelimiterLimit(&line_writer, '\n', .limited(remaining)) catch |err| switch (err) {
            error.StreamTooLong, error.WriteFailed => return error.McpResponseTooLarge,
            else => return err,
        };
        consumed += n;
        const line = std.mem.trimEnd(u8, line_writer.buffered(), "\r");

        var at_eof = false;
        const delimiter = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => blk: {
                at_eof = true;
                break :blk 0;
            },
            else => return err,
        };
        if (!at_eof) {
            std.debug.assert(delimiter == '\n');
            consumed += 1;
        }

        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trimStart(u8, line["data:".len..], " \t");
            if (event_data.items.len > 0) try event_data.append(gpa, '\n');
            if (event_data.items.len + data.len > max_http_response) return error.McpResponseTooLarge;
            try event_data.appendSlice(gpa, data);
        }

        if (line.len == 0 or at_eof) {
            if (event_data.items.len > 0) {
                return try gpa.dupe(u8, event_data.items);
            }
        }
        if (at_eof) break;
    }
    return null;
}

pub const HttpClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    url_owned: bool,
    client: std.http.Client,
    next_id: i64 = 1,
    modern: ?McpClient.ModernIdentity = null,
    bearer_token: ?[]const u8 = null,
    timeout_secs: u32 = 15,

    /// `endpoint`: "host:port" (plain http, loopback only), or a full
    /// "http://…" / "https://…" URL (path preserved, e.g. /mcp).
    /// Enforces the validRemoteUrl policy.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, endpoint: []const u8) !HttpClient {
        var url: []const u8 = endpoint;
        var owned = false;
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            if (std.mem.endsWith(u8, url, "/")) url = url[0 .. url.len - 1];
            var host_part = url;
            if (std.mem.lastIndexOfScalar(u8, url, ':')) |colon| host_part = url[0..colon];
            if (std.ascii.eqlIgnoreCase(host_part, "localhost")) {
                url = try std.fmt.allocPrint(alloc, "http://127.0.0.1{s}/mcp", .{url["localhost".len..]});
            } else {
                url = try std.fmt.allocPrint(alloc, "http://{s}/mcp", .{url});
            }
            owned = true;
        }
        if (!validRemoteUrl(url)) {
            if (owned) alloc.free(url);
            return error.InsecureEndpoint;
        }
        return .{
            .alloc = alloc,
            .io = io,
            .url = url,
            .url_owned = owned,
            .client = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        if (self.url_owned) self.alloc.free(self.url);
    }

    /// Stamp every request with _meta (protocolVersion/clientInfo/caps).
    pub fn useModern(self: *HttpClient, identity: McpClient.ModernIdentity) void {
        self.modern = identity;
    }

    /// Bearer token for servers with authorization enabled.
    pub fn setBearer(self: *HttpClient, token: []const u8) void {
        self.bearer_token = token;
    }

    /// Detect the server's protocol era: server/discover with modern _meta.
    /// .modern → call useModern and proceed statelessly; .legacy → use the
    /// legacy HTTP flow (or stdio); .unsupported_version → our versions don't
    /// overlap; .incompatible → not a (modern) MCP server.
    pub fn probe(self: *HttpClient) !Probe {
        const saved = self.modern;
        self.modern = saved orelse .{ .name = "mcp-zig-probe", .version = "1" };
        defer self.modern = saved;
        const body = self.call("server/discover", null, "{}") catch |err| switch (err) {
            error.AuthenticationRequired => return error.AuthenticationRequired,
            else => return .incompatible,
        };
        defer self.alloc.free(body);
        if (json.scanObj(body, "result") != null) return .modern;
        return classifyProbe(body);
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

    fn buildHeaders(self: *HttpClient, arena: std.mem.Allocator, method: []const u8, mcp_name: ?[]const u8) ![]std.http.Header {
        var list: std.ArrayList(std.http.Header) = .empty;
        try list.append(arena, .{ .name = "accept", .value = "application/json, text/event-stream" });
        if (self.modern) |mid| {
            try list.append(arena, .{ .name = "mcp-protocol-version", .value = mid.protocol_version });
            try list.append(arena, .{ .name = "mcp-method", .value = method });
            if (mcp_name) |n| try list.append(arena, .{ .name = "mcp-name", .value = try headerValueEncoded(arena, n) });
        }
        if (self.bearer_token) |t| {
            try list.append(arena, .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) });
        }
        return list.items;
    }

    /// One JSON-RPC POST. `mcp_name` is required for tools/call.
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

        const result = try self.post(body.items, method, mcp_name);
        return result orelse error.BadResponse;
    }

    // ── transport internals (codegraff mcp_http.zig patterns) ───────────────

    fn postUnwatched(self: *HttpClient, body: []const u8, method: []const u8, mcp_name: ?[]const u8) !?[]u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const extra = try self.buildHeaders(arena_state.allocator(), method, mcp_name);

        var req = try self.client.request(.POST, try std.Uri.parse(self.url), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
                .user_agent = .{ .override = "mcp-zig/1" },
            },
            .extra_headers = extra,
        });
        defer req.deinit();
        errdefer if (req.connection) |connection| {
            connection.closing = true;
        };

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();
        var response = try req.receiveHead(&.{});

        const status = @intFromEnum(response.head.status);
        if (status == 401 or status == 403) {
            if (req.connection) |connection| connection.closing = true;
            return error.AuthenticationRequired;
        }
        // 400/404 carry JSON-RPC error bodies in modern MCP — surface them
        // like a normal response so callers see HeaderMismatch/-32601 etc.
        const passthrough = (status >= 200 and status < 300) or status == 400 or status == 404;
        if (!passthrough) {
            if (req.connection) |connection| connection.closing = true;
            return error.HttpStatus;
        }

        if (response.head.content_length == 0) return null;
        const is_sse = if (response.head.content_type) |content_type|
            std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")
        else
            false;
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        if (is_sse) return readSseResponse(self.alloc, reader);

        const response_buf = try self.alloc.alloc(u8, max_http_response);
        errdefer self.alloc.free(response_buf);
        var fixed = std.Io.Writer.fixed(response_buf);
        _ = reader.streamRemaining(&fixed) catch |err| switch (err) {
            error.WriteFailed => return error.McpResponseTooLarge,
            else => return err,
        };
        const len = fixed.buffered().len;
        if (len == 0) {
            self.alloc.free(response_buf);
            return null;
        }
        return try self.alloc.realloc(response_buf, len);
    }

    const PostDone = union(enum) {
        posted: anyerror!?[]u8,
        timeout,
    };

    fn postTask(self: *HttpClient, body: []const u8, method: []const u8, mcp_name: ?[]const u8) anyerror!?[]u8 {
        return self.postUnwatched(body, method, mcp_name);
    }

    fn timeoutTask(io: std.Io, secs: u32) void {
        io.sleep(.fromSeconds(secs), .awake) catch {};
    }

    fn freeLatePost(allocator: std.mem.Allocator, result: anyerror!?[]u8) void {
        if (result) |body| {
            if (body) |bytes| allocator.free(bytes);
        } else |_| {}
    }

    fn cancelPost(select: *std.Io.Select(PostDone), allocator: std.mem.Allocator) void {
        while (select.cancel()) |late| switch (late) {
            .posted => |result| freeLatePost(allocator, result),
            .timeout => {},
        };
    }

    /// Race network I/O against a hard deadline. Cancellation unwinds the
    /// request, whose errdefer poisons the connection so a timed-out socket
    /// is never pooled.
    fn post(self: *HttpClient, body: []const u8, method: []const u8, mcp_name: ?[]const u8) !?[]u8 {
        var done_buf: [2]PostDone = undefined;
        var select: std.Io.Select(PostDone) = .init(self.io, &done_buf);
        select.concurrent(.posted, postTask, .{ self, body, method, mcp_name }) catch
            return error.McpRequestTimedOut;
        select.concurrent(.timeout, timeoutTask, .{ self.io, self.timeout_secs }) catch {
            const only = select.await() catch |err| {
                cancelPost(&select, self.alloc);
                return err;
            };
            select.cancelDiscard();
            return only.posted;
        };

        const first = select.await() catch |err| {
            cancelPost(&select, self.alloc);
            return err;
        };
        switch (first) {
            .posted => |result| {
                select.cancelDiscard();
                return result;
            },
            .timeout => {
                cancelPost(&select, self.alloc);
                return error.McpRequestTimedOut;
            },
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "validRemoteUrl policy" {
    const testing = std.testing;
    try testing.expect(validRemoteUrl("https://mcp.example.com/mcp"));
    try testing.expect(validRemoteUrl("http://localhost:8000/mcp"));
    try testing.expect(validRemoteUrl("http://127.0.0.1:8000/mcp"));
    try testing.expect(validRemoteUrl("http://[::1]:8000/mcp"));
    try testing.expect(!validRemoteUrl("http://example.com/mcp"));
    try testing.expect(!validRemoteUrl("ftp://example.com"));
    try testing.expect(!validRemoteUrl("not a url"));
}

test "modernErrorCode classification" {
    const testing = std.testing;
    try testing.expectEqual(ModernError.header_mismatch, modernErrorCode(-32020).?);
    try testing.expectEqual(ModernError.missing_capability, modernErrorCode(-32021).?);
    try testing.expectEqual(ModernError.unsupported_version, modernErrorCode(-32022).?);
    try testing.expect(modernErrorCode(-32601) == null);
    try testing.expect(modernErrorCode(-32003) == null); // grandfathered range
}

test "classifyProbe: modern, legacy, unsupported, incompatible" {
    const testing = std.testing;
    try testing.expectEqual(Probe.modern, classifyProbe("{\"error\":{\"code\":-32020,\"message\":\"Header mismatch\"}}"));
    try testing.expectEqual(Probe.legacy, classifyProbe("{\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"));
    try testing.expectEqual(Probe.legacy, classifyProbe(""));
    try testing.expectEqual(Probe.legacy, classifyProbe("not json at all"));
    try testing.expectEqual(Probe.unsupported_version, classifyProbe("{\"error\":{\"code\":-32022,\"data\":{\"requested\":\"2099-01-01\",\"supported\":[\"2026-07-28\"]}}}"));
    try testing.expectEqual(Probe.incompatible, classifyProbe("{\"error\":{\"code\":-32022,\"data\":{\"supported\":[\"1999-01-01\"]}}}"));
}

test "headerValueEncoded: safe passthrough, base64 sentinel for unsafe" {
    const testing = std.testing;
    const safe = try headerValueEncoded(testing.allocator, "get_weather");
    defer testing.allocator.free(safe);
    try testing.expectEqualStrings("get_weather", safe);

    const unsafe = try headerValueEncoded(testing.allocator, "file:///x\ny");
    defer testing.allocator.free(unsafe);
    try testing.expect(std.mem.startsWith(u8, unsafe, "=?base64?"));
    try testing.expect(std.mem.endsWith(u8, unsafe, "?="));

    // already-sentinel-shaped values are force-encoded to avoid ambiguity
    const sneaky = try headerValueEncoded(testing.allocator, "=?x?=");
    defer testing.allocator.free(sneaky);
    try testing.expect(std.mem.startsWith(u8, sneaky, "=?base64?"));
}

test "readSseResponse: single event, multi-line data, comments" {
    const testing = std.testing;
    const sse = ": comment line\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":1}\r\n\r\n";
    var reader = std.Io.Reader.fixed(sse);
    const event = (try readSseResponse(testing.allocator, &reader)).?;
    defer testing.allocator.free(event);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\n\"id\":1}", event);
}

test "HttpClient.init parsing and policy" {
    const testing = std.testing;
    var c = try HttpClient.init(testing.allocator, std.testing.io, "127.0.0.1:8000");
    defer c.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:8000/mcp", c.url);

    var c2 = try HttpClient.init(testing.allocator, std.testing.io, "https://mcp.example.com/mcp");
    defer c2.deinit();
    try testing.expectEqualStrings("https://mcp.example.com/mcp", c2.url);

    var c3 = try HttpClient.init(testing.allocator, std.testing.io, "localhost:3000");
    defer c3.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:3000/mcp", c3.url);

    try testing.expectError(error.InsecureEndpoint, HttpClient.init(testing.allocator, std.testing.io, "http://example.com/mcp"));
}
