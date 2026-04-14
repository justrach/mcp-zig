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
//   var client = try McpClient.init(alloc, &.{"/path/to/server"}, null);
//   defer client.deinit();
//   try client.initialize();
//   const tools = try client.listTools();
//   const result = try client.callTool("read_file", "{\"path\":\"hello.txt\"}");

const std = @import("std");
const json = @import("json.zig");

pub const McpClient = struct {
    alloc: std.mem.Allocator,
    process: std.process.Child,
    next_id: i64,
    // Buffered reading state — avoids per-byte syscalls in readOneLine
    stdout_buf: [4096]u8 = undefined,
    stdout_pos: usize = 0,
    stdout_len: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        cwd: ?[]const u8,
    ) !McpClient {
        var child = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (cwd) |d| child.cwd = d;
        try child.spawn();
        return .{
            .alloc = alloc,
            .process = child,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *McpClient) void {
        // Close stdin first to signal the server to exit, then wait.
        // Don't close stdout/stderr manually — process.wait() handles cleanup.
        if (self.process.stdin) |*s| {
            s.close();
            self.process.stdin = null;
        }
        _ = self.process.wait() catch {};
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
        _ = try stdin.write(msg);
    }

    /// List available tools. Returns raw JSON result string.
    pub fn listTools(self: *McpClient) ![]u8 {
        const req =
            \\{"jsonrpc":"2.0","id":__ID__,"method":"tools/list","params":{}}
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
        buf.appendSlice(self.alloc, "}}\n") catch return error.OutOfMemory;

        const stdin = self.process.stdin orelse return error.StdinClosed;
        _ = try stdin.write(buf.items);

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
        _ = try stdin.write(buf.items);

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
    /// Uses internal 4KB buffer to batch syscalls — typically 1 read per response
    /// instead of 1 read per byte.
    fn readOneLine(self: *McpClient) ![]u8 {
        const stdout = self.process.stdout orelse return error.StdoutClosed;

        var line: std.ArrayList(u8) = .empty;
        while (true) {
            // Refill buffer if exhausted
            if (self.stdout_pos >= self.stdout_len) {
                const n = try stdout.read(&self.stdout_buf);
                if (n == 0) {
                    if (line.items.len > 0) {
                        return line.toOwnedSlice(self.alloc) catch {
                            line.deinit(self.alloc);
                            return error.OutOfMemory;
                        };
                    }
                    line.deinit(self.alloc);
                    return error.ServerClosed;
                }
                self.stdout_pos = 0;
                self.stdout_len = n;
            }

            // Scan for newline in buffered data
            const remaining = self.stdout_buf[self.stdout_pos..self.stdout_len];
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
                line.appendSlice(self.alloc, remaining[0..nl_pos]) catch {
                    line.deinit(self.alloc);
                    return error.OutOfMemory;
                };
                self.stdout_pos += nl_pos + 1;
                break;
            } else {
                line.appendSlice(self.alloc, remaining) catch {
                    line.deinit(self.alloc);
                    return error.OutOfMemory;
                };
                self.stdout_pos = self.stdout_len;
            }

            if (line.items.len > json.MAX_LINE) {
                line.deinit(self.alloc);
                return error.ResponseTooLarge;
            }
        }

        return line.toOwnedSlice(self.alloc) catch {
            line.deinit(self.alloc);
            return error.OutOfMemory;
        };
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
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch {
            // Fallback: empty roots
            buf.clearRetainingCapacity();
            buf.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
            appendId(self.alloc, &buf, id);
            buf.appendSlice(self.alloc, ",\"result\":{\"roots\":[]}}\n") catch return;
            const stdin = self.process.stdin orelse return;
            _ = stdin.write(buf.items) catch {};
            return;
        };
        json.writeEscaped(self.alloc, &buf, cwd);
        buf.appendSlice(self.alloc, "\",\"name\":\"workspace\"}]}}\n") catch return;

        const stdin = self.process.stdin orelse return;
        _ = stdin.write(buf.items) catch {};
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
        _ = stdin.write(buf.items) catch {};
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
    server_argv: []const []const u8,
    tool_name: []const u8,
    args_json: []const u8,
) ![]u8 {
    var client = try McpClient.init(alloc, server_argv, null);
    defer client.deinit();

    const init_result = try client.initialize();
    alloc.free(init_result);
    try client.notifyInitialized();

    return client.callTool(tool_name, args_json);
}
