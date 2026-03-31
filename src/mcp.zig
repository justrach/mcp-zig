// mcp-zig — MCP server (Model Context Protocol, JSON-RPC 2.0 over stdio)
//
// Protocol version: 2025-06-18
// Protocol: newline-delimited JSON. NO Content-Length headers (unlike LSP).
// Claude Code's ReadBuffer parses one JSON object per line — a single \n
// inside a result would be interpreted as a new (invalid) request.
//
// The critical invariant: every write to stdout is exactly one JSON object
// followed by exactly one \n. `writeResult` enforces this by stripping \n
// from result strings before embedding them.
//
// Lifecycle:
//   1. Claude Code spawns this process with `--mcp` (or however you route it)
//   2. Sends {"jsonrpc":"2.0","id":1,"method":"initialize",...}
//   3. Sends {"jsonrpc":"2.0","method":"notifications/initialized"} (no id)
//   4. Sends tools/list, tools/call as needed
//   5. Process exits when stdin closes
//
// Supported features:
//   - Client capability parsing (roots, etc.)
//   - Workspace roots (roots/list, notifications/roots/list_changed)
//   - Logging (logging/setLevel, notifications/message)
//   - Progress notifications (notifications/progress)
//   - Request cancellation (notifications/cancelled)
//   - Structured tool output (structuredContent in CallToolResult)
//   - Server instructions in initialize result
//   - Bidirectional JSON-RPC (server → client requests)

const std = @import("std");
const json = @import("json.zig");
const tools = @import("tools.zig");

// ── Log levels (RFC 5424 severity) ──────────────────────────────────────────

pub const LogLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,
};

fn logLevelFromString(s: []const u8) ?LogLevel {
    inline for (std.meta.fields(LogLevel)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Workspace root provided by the client via the roots capability.
/// URIs use file:// scheme. Roots scope the server's view of the filesystem.
pub const Root = struct {
    uri: []u8,
    name: []u8,
};

/// MCP session state — tracks client capabilities, workspace roots, and log level.
const Session = struct {
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    next_id: i64 = 100, // start high to avoid collision with client IDs

    // Client capabilities (parsed from initialize request)
    client_supports_roots: bool = false,
    client_roots_list_changed: bool = false,

    // Server-to-client request tracking
    pending_roots_id: ?i64 = null,

    // Workspace roots from the client
    roots: std.ArrayList(Root) = .empty,

    // Logging (#3)
    log_level: LogLevel = .warning,

    fn freeRoots(self: *Session) void {
        for (self.roots.items) |r| {
            self.alloc.free(r.uri);
            self.alloc.free(r.name);
        }
        self.roots.clearRetainingCapacity();
    }

    fn deinit(self: *Session) void {
        self.freeRoots();
        self.roots.deinit(self.alloc);
    }
};

pub fn run(alloc: std.mem.Allocator) void {
    var session: Session = .{
        .alloc = alloc,
        .stdout = std.fs.File.stdout(),
    };
    defer session.deinit();
    const stdin = std.fs.File.stdin();

    while (true) {
        const line = json.readLine(alloc, stdin) orelse break;
        defer alloc.free(line);

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch {
            writeError(alloc, session.stdout, null, -32700, "Parse error");
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            writeError(alloc, session.stdout, null, -32600, "Invalid Request");
            continue;
        }

        const root = &parsed.value.object;

        // Dispatch: requests/notifications have "method", responses do not
        if (json.getStr(root, "method")) |method| {
            const id = root.get("id");

            if (json.eql(method, "initialize")) {
                handleInitialize(&session, root, id);
            } else if (json.eql(method, "notifications/initialized")) {
                // Post-handshake: request workspace roots if client supports them
                if (session.client_supports_roots) requestRoots(&session);
            } else if (json.eql(method, "notifications/roots/list_changed")) {
                // Client's workspace roots changed — re-query
                if (session.client_supports_roots) requestRoots(&session);
            } else if (json.eql(method, "notifications/cancelled")) {
                // (#4) Accept cancellation — tools are synchronous, nothing to abort
            } else if (json.eql(method, "logging/setLevel")) {
                // (#3) Update minimum log level
                handleSetLogLevel(&session, root, id);
            } else if (json.eql(method, "tools/list")) {
                writeResult(alloc, session.stdout, id, tools.tools_list);
            } else if (json.eql(method, "tools/call")) {
                handleCall(&session, root, id);
            } else if (json.eql(method, "ping")) {
                writeResult(alloc, session.stdout, id, "{}");
            } else {
                if (id != null) writeError(alloc, session.stdout, id, -32601, "Method not found");
            }
        } else if (root.get("result") != null or root.get("error") != null) {
            // Response to a server-initiated request
            handleResponse(&session, root);
        } else {
            writeError(alloc, session.stdout, null, -32600, "Missing method");
        }
    }
}

// ── initialize ─────────────────────────────────────────────────────────────
//
// Parse client capabilities and respond with server capabilities.
// Change "name", "version", and "instructions" to match your server.

fn handleInitialize(s: *Session, root: *const std.json.ObjectMap, id: ?std.json.Value) void {
    // Parse client capabilities from params.capabilities
    caps: {
        const p = root.get("params") orelse break :caps;
        if (p != .object) break :caps;
        const c = p.object.get("capabilities") orelse break :caps;
        if (c != .object) break :caps;
        const r = c.object.get("roots") orelse break :caps;
        s.client_supports_roots = true;
        if (r == .object) {
            var obj = r.object;
            s.client_roots_list_changed = json.getBool(&obj, "listChanged");
        }
    }

    // (#5) instructions + (#3) logging capability
    writeResult(s.alloc, s.stdout, id,
        \\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false},"logging":{}},"serverInfo":{"name":"mcp-zig","title":"MCP Zig Server","version":"1.0.0"},"instructions":"MCP Zig server providing filesystem tools. Use read_file to read file contents and list_dir to list directory entries."}
    );
}

// ── logging (#3) ───────────────────────────────────────────────────────────
//
// logging/setLevel — client sets the minimum log level.
// notifications/message — server sends log messages to client.

fn handleSetLogLevel(s: *Session, root: *const std.json.ObjectMap, id: ?std.json.Value) void {
    level: {
        const p = root.get("params") orelse break :level;
        if (p != .object) break :level;
        const lv = p.object.get("level") orelse break :level;
        if (lv != .string) break :level;
        s.log_level = logLevelFromString(lv.string) orelse break :level;
    }
    writeResult(s.alloc, s.stdout, id, "{}");
}

/// Send a log notification to the client if level >= session log_level.
pub fn writeLogNotification(s: *Session, level: LogLevel, data: []const u8) void {
    if (@intFromEnum(level) < @intFromEnum(s.log_level)) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(s.alloc);

    buf.appendSlice(s.alloc, "{\"level\":\"") catch return;
    buf.appendSlice(s.alloc, @tagName(level)) catch return;
    buf.appendSlice(s.alloc, "\",\"logger\":\"mcp-zig\",\"data\":\"") catch return;
    json.writeEscaped(s.alloc, &buf, data);
    buf.appendSlice(s.alloc, "\"}") catch return;

    writeNotification(s.alloc, s.stdout, "notifications/message", buf.items);
}

// ── progress (#2, #6) ──────────────────────────────────────────────────────
//
// notifications/progress — report progress for long-running operations.
// The progressToken comes from params._meta.progressToken in tools/call.

/// Send a progress notification to the client.
/// `token` is the raw JSON value from _meta.progressToken (string or integer).
pub fn writeProgressNotification(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    token: std.json.Value,
    progress: usize,
    total: usize,
    message: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"progressToken\":") catch return;
    appendJsonValue(alloc, &buf, token);
    buf.appendSlice(alloc, ",\"progress\":") catch return;
    var tmp: [20]u8 = undefined;
    const ps = std.fmt.bufPrint(&tmp, "{d}", .{progress}) catch return;
    buf.appendSlice(alloc, ps) catch return;
    buf.appendSlice(alloc, ",\"total\":") catch return;
    const ts = std.fmt.bufPrint(&tmp, "{d}", .{total}) catch return;
    buf.appendSlice(alloc, ts) catch return;
    if (message.len > 0) {
        buf.appendSlice(alloc, ",\"message\":\"") catch return;
        json.writeEscaped(alloc, &buf, message);
        buf.appendSlice(alloc, "\"") catch return;
    }
    buf.appendSlice(alloc, "}") catch return;

    writeNotification(alloc, stdout, "notifications/progress", buf.items);
}

// ── roots ──────────────────────────────────────────────────────────────────

fn requestRoots(s: *Session) void {
    const id = s.next_id;
    s.next_id += 1;
    s.pending_roots_id = id;
    writeRequest(s.alloc, s.stdout, id, "roots/list", "{}");
}

fn handleResponse(s: *Session, root: *const std.json.ObjectMap) void {
    const resp_id_val = root.get("id") orelse return;
    const resp_id = switch (resp_id_val) {
        .integer => |n| n,
        else => return,
    };

    if (s.pending_roots_id) |rid| {
        if (resp_id == rid) {
            s.pending_roots_id = null;
            if (root.get("result")) |result_val| {
                if (result_val == .object) {
                    var result_obj = result_val.object;
                    parseRoots(s, &result_obj);
                }
            }
        }
    }
}

fn parseRoots(s: *Session, result: *const std.json.ObjectMap) void {
    s.freeRoots();
    const roots_val = result.get("roots") orelse return;
    if (roots_val != .array) return;

    for (roots_val.array.items) |item| {
        if (item != .object) continue;
        var obj = item.object;
        const uri_raw = json.getStr(&obj, "uri") orelse continue;
        const name_raw = json.getStr(&obj, "name") orelse "";
        const uri = s.alloc.dupe(u8, uri_raw) catch continue;
        const name = s.alloc.dupe(u8, name_raw) catch {
            s.alloc.free(uri);
            continue;
        };
        s.roots.append(s.alloc, .{ .uri = uri, .name = name }) catch {
            s.alloc.free(uri);
            s.alloc.free(name);
        };
    }

    // Log roots via MCP logging (#3) and stderr
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Workspace roots updated: {d} root(s)", .{s.roots.items.len}) catch return;
    writeLogNotification(s, .info, msg);

    for (s.roots.items) |r| {
        if (r.name.len > 0) {
            std.debug.print("[mcp-zig] root: {s} ({s})\n", .{ r.uri, r.name });
        } else {
            std.debug.print("[mcp-zig] root: {s}\n", .{r.uri});
        }
    }
}

// ── tools/call ────────────────────────────────────────────────────────────

fn handleCall(
    s: *Session,
    root: *const std.json.ObjectMap,
    id: ?std.json.Value,
) void {
    const alloc = s.alloc;
    const stdout = s.stdout;

    // Unwrap params
    const params_val = root.get("params") orelse {
        writeError(alloc, stdout, id, -32602, "Missing params"); return;
    };
    if (params_val != .object) {
        writeError(alloc, stdout, id, -32602, "params must be object"); return;
    }
    const params = &params_val.object;

    // (#6) Extract _meta.progressToken if present
    const progress_token: ?std.json.Value = meta: {
        const meta_val = params.get("_meta") orelse break :meta null;
        if (meta_val != .object) break :meta null;
        break :meta meta_val.object.get("progressToken");
    };
    _ = progress_token; // available for future use when tools get context passing

    // Tool name
    const name = json.getStr(params, "name") orelse {
        writeError(alloc, stdout, id, -32602, "Missing tool name"); return;
    };

    // Arguments
    const args_val = params.get("arguments") orelse {
        writeError(alloc, stdout, id, -32602, "Missing arguments"); return;
    };
    if (args_val != .object) {
        writeError(alloc, stdout, id, -32602, "arguments must be object"); return;
    }
    const args = &args_val.object;

    // Dispatch
    const tool = tools.parse(name) orelse {
        writeError(alloc, stdout, id, -32602, "Unknown tool"); return;
    };

    // Run handler → capture output → wrap in MCP content envelope
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    tools.dispatch(alloc, tool, args, &out);

    // (#1) Build result with optional structuredContent
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    result.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(alloc, &result, out.items);
    result.appendSlice(alloc, "\"}],\"isError\":false") catch return;

    // If output looks like a JSON object, try to include it as structuredContent
    if (out.items.len > 0 and out.items[0] == '{') {
        if (isValidJsonObject(alloc, out.items)) {
            result.appendSlice(alloc, ",\"structuredContent\":") catch return;
            result.appendSlice(alloc, out.items) catch return;
        }
    }

    result.appendSlice(alloc, "}") catch return;
    writeResult(alloc, stdout, id, result.items);
}

/// Quick check: is this a parseable JSON object?
fn isValidJsonObject(alloc: std.mem.Allocator, data: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

// ── JSON-RPC 2.0 writers ────────────────────────────────────────────────────

/// Write a JSON-RPC 2.0 result response.
/// IMPORTANT: strips \n and \r from `result` before writing.
fn writeResult(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    result: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    for (result) |c| {
        if (c != '\n' and c != '\r') buf.append(alloc, c) catch return;
    }
    buf.appendSlice(alloc, "}\n") catch return;

    _ = stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 error response.
fn writeError(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    code: i32,
    msg: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    json.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}\n") catch return;

    _ = stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 notification (no id, no response expected).
fn writeNotification(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    method: []const u8,
    params: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    for (params) |c| {
        if (c != '\n' and c != '\r') buf.append(alloc, c) catch return;
    }
    buf.appendSlice(alloc, "}\n") catch return;

    _ = stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 request (server → client).
fn writeRequest(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: i64,
    method: []const u8,
    params: []const u8,
) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    var tmp: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&tmp, "{d}", .{id}) catch return;
    buf.appendSlice(alloc, id_str) catch return;
    buf.appendSlice(alloc, ",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    buf.appendSlice(alloc, params) catch return;
    buf.appendSlice(alloc, "}\n") catch return;

    _ = stdout.write(buf.items) catch 0;
}

/// Append a JSON value (string or integer) to buf — used for progressToken.
fn appendJsonValue(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), val: std.json.Value) void {
    switch (val) {
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
    }
}

fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    if (id) |v| {
        appendJsonValue(alloc, buf, v);
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}
