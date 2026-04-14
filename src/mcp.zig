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

    // Reusable buffers — allocated once, cleared between requests (Rust BytesMut pattern).
    // Avoids per-request alloc/free cycles in the hot path.
    write_buf: std.ArrayList(u8) = .empty,
    tool_buf: std.ArrayList(u8) = .empty,
    line_buf: std.ArrayList(u8) = .empty,

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
        self.write_buf.deinit(self.alloc);
        self.tool_buf.deinit(self.alloc);
        self.line_buf.deinit(self.alloc);
    }
};

pub fn run(alloc: std.mem.Allocator) void {
    var session: Session = .{
        .alloc = alloc,
        .stdout = std.fs.File.stdout(),
    };
    defer session.deinit();
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&read_buf);

    // Comptime perfect-hash method dispatch table — O(1) lookup, no sequential string comparisons.
    const Method = enum { ping, tools_list, tools_call, initialize, logging_setLevel, notif_initialized, notif_roots_changed, notif_cancelled };
    const method_map = std.StaticStringMap(Method).initComptime(.{
        .{ "ping", .ping },
        .{ "tools/list", .tools_list },
        .{ "tools/call", .tools_call },
        .{ "initialize", .initialize },
        .{ "logging/setLevel", .logging_setLevel },
        .{ "notifications/initialized", .notif_initialized },
        .{ "notifications/roots/list_changed", .notif_roots_changed },
        .{ "notifications/cancelled", .notif_cancelled },
    });

    while (true) {
        // Read line into reusable buffer (no allocation after first iteration)
        const line = json.readLineInto(alloc, &stdin_reader.interface, &session.line_buf) orelse break;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        // Fast scan: extract method + id without building a JSON tree.
        // For ping, tools/list, and notifications this is all we need — zero allocs.
        const scan = json.scanJsonRpc(input);

        if (scan.method) |method| {
            if (method_map.get(method)) |m| switch (m) {
                // Fast path: no JSON parse needed — zero allocations
                .ping => writeResultRaw(&session, scan.id_raw, "{}"),
                .tools_list => writeResultRaw(&session, scan.id_raw, tools.tools_list),
                .notif_initialized => { if (session.client_supports_roots) requestRoots(&session); },
                .notif_roots_changed => { if (session.client_supports_roots) requestRoots(&session); },
                .notif_cancelled => {},

                // Slow path: needs params — full JSON parse
                .initialize, .logging_setLevel, .tools_call => {
                    const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch {
                        writeErrorRaw(&session, scan.id_raw, -32700, "Parse error");
                        continue;
                    };
                    defer parsed.deinit();

                    if (parsed.value != .object) {
                        writeErrorRaw(&session, scan.id_raw, -32600, "Invalid Request");
                        continue;
                    }
                    const root = &parsed.value.object;
                    const id = root.get("id");

                    switch (m) {
                        .initialize => handleInitialize(&session, root, id),
                        .logging_setLevel => handleSetLogLevel(&session, root, id),
                        .tools_call => handleCall(&session, root, id),
                        else => unreachable,
                    }
                },
            } else {
                // Unknown method — error if it has an id (request), ignore if notification
                if (scan.id_raw != null) writeErrorRaw(&session, scan.id_raw, -32601, "Method not found");
            }
        } else if (scan.has_result or scan.has_error) {
            // Response to a server-initiated request — needs full parse
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value == .object) {
                var obj = parsed.value.object;
                handleResponse(&session, &obj);
            }
        } else {
            writeErrorRaw(&session, null, -32600, "Missing method");
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
    writeResult(s, id,
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
    writeResult(s, id, "{}");
}

/// Send a log notification to the client if level >= session log_level.
pub fn writeLogNotification(s: *Session, level: LogLevel, data: []const u8) void {
    if (@intFromEnum(level) < @intFromEnum(s.log_level)) return;

    const alloc = s.alloc;
    // Reuse tool_buf for building the notification params (write_buf is used by writeNotification)
    s.tool_buf.clearRetainingCapacity();
    s.tool_buf.appendSlice(alloc, "{\"level\":\"") catch return;
    s.tool_buf.appendSlice(alloc, @tagName(level)) catch return;
    s.tool_buf.appendSlice(alloc, "\",\"logger\":\"mcp-zig\",\"data\":\"") catch return;
    json.writeEscaped(alloc, &s.tool_buf, data);
    s.tool_buf.appendSlice(alloc, "\"}") catch return;

    writeNotification(s, "notifications/message", s.tool_buf.items);
}

// ── progress (#2, #6) ──────────────────────────────────────────────────────
//
// notifications/progress — report progress for long-running operations.
// The progressToken comes from params._meta.progressToken in tools/call.

/// Send a progress notification to the client.
/// `token` is the raw JSON value from _meta.progressToken (string or integer).
pub fn writeProgressNotification(
    s: *Session,
    token: std.json.Value,
    progress: usize,
    total: usize,
    message: []const u8,
) void {
    const alloc = s.alloc;
    s.tool_buf.clearRetainingCapacity();
    s.tool_buf.appendSlice(alloc, "{\"progressToken\":") catch return;
    appendJsonValue(alloc, &s.tool_buf, token);
    s.tool_buf.appendSlice(alloc, ",\"progress\":") catch return;
    var tmp: [20]u8 = undefined;
    const ps = std.fmt.bufPrint(&tmp, "{d}", .{progress}) catch return;
    s.tool_buf.appendSlice(alloc, ps) catch return;
    s.tool_buf.appendSlice(alloc, ",\"total\":") catch return;
    const ts = std.fmt.bufPrint(&tmp, "{d}", .{total}) catch return;
    s.tool_buf.appendSlice(alloc, ts) catch return;
    if (message.len > 0) {
        s.tool_buf.appendSlice(alloc, ",\"message\":\"") catch return;
        json.writeEscaped(alloc, &s.tool_buf, message);
        s.tool_buf.appendSlice(alloc, "\"") catch return;
    }
    s.tool_buf.appendSlice(alloc, "}") catch return;

    writeNotification(s, "notifications/progress", s.tool_buf.items);
}

// ── roots ──────────────────────────────────────────────────────────────────

fn requestRoots(s: *Session) void {
    const id = s.next_id;
    s.next_id += 1;
    s.pending_roots_id = id;
    writeRequest(s, id, "roots/list", "{}");
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

    // Unwrap params
    const params_val = root.get("params") orelse {
        writeError(s, id, -32602, "Missing params"); return;
    };
    if (params_val != .object) {
        writeError(s, id, -32602, "params must be object"); return;
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
        writeError(s, id, -32602, "Missing tool name"); return;
    };

    // Arguments
    const args_val = params.get("arguments") orelse {
        writeError(s, id, -32602, "Missing arguments"); return;
    };
    if (args_val != .object) {
        writeError(s, id, -32602, "arguments must be object"); return;
    }
    const args = &args_val.object;

    // Dispatch
    const tool = tools.parse(name) orelse {
        writeError(s, id, -32602, "Unknown tool"); return;
    };

    // Run handler into reusable tool_buf (clear, not free)
    s.tool_buf.clearRetainingCapacity();
    tools.dispatch(alloc, tool, args, &s.tool_buf);

    // Build the complete JSON-RPC response directly into write_buf.
    // We write the full envelope here (not via writeResult) because the
    // content envelope is built in-place and we can't pass a slice of
    // write_buf to writeResult (which also uses write_buf).
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.ensureTotalCapacity(alloc, 120 + s.tool_buf.items.len * 2) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, buf, id);
    buf.appendSlice(alloc, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(alloc, buf, s.tool_buf.items);
    buf.appendSlice(alloc, "\"}],\"isError\":false") catch return;

    // If output looks like a JSON object, include as structuredContent
    if (s.tool_buf.items.len > 0 and s.tool_buf.items[0] == '{') {
        if (isValidJsonObject(s.tool_buf.items)) {
            buf.appendSlice(alloc, ",\"structuredContent\":") catch return;
            buf.appendSlice(alloc, s.tool_buf.items) catch return;
        }
    }

    buf.appendSlice(alloc, "}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Lightweight check for whether data looks like a complete JSON object.
/// Lightweight check for whether data looks like a complete JSON object.
/// Validates balanced braces and proper string handling without a full parse.
/// This avoids re-parsing potentially large tool output just to check structure.
fn isValidJsonObject(data: []const u8) bool {
    if (data.len < 2 or data[0] != '{') return false;
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
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

// ── JSON-RPC 2.0 writers (reuse s.write_buf across calls) ────────────────────

/// Write a result response using a raw id string (from scanner — avoids JSON parse).
fn writeResultRaw(s: *Session, id_raw: ?[]const u8, result: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.ensureTotalCapacity(alloc, 40 + result.len) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(alloc, id_raw orelse "null") catch return;
    buf.appendSlice(alloc, ",\"result\":") catch return;
    appendStrippingNewlines(alloc, buf, result);
    buf.appendSlice(alloc, "}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Write an error response using a raw id string (from scanner — avoids JSON parse).
fn writeErrorRaw(s: *Session, id_raw: ?[]const u8, code: i32, msg: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(alloc, id_raw orelse "null") catch return;
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    json.writeEscaped(alloc, buf, msg);
    buf.appendSlice(alloc, "\"}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 result response.
fn writeResult(s: *Session, id: ?std.json.Value, result: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.ensureTotalCapacity(alloc, 40 + result.len) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    appendStrippingNewlines(alloc, buf, result);
    buf.appendSlice(alloc, "}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 error response.
fn writeError(s: *Session, id: ?std.json.Value, code: i32, msg: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    json.writeEscaped(alloc, buf, msg);
    buf.appendSlice(alloc, "\"}}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 notification (no id, no response expected).
fn writeNotification(s: *Session, method: []const u8, params: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.ensureTotalCapacity(alloc, 40 + method.len + params.len) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    appendStrippingNewlines(alloc, buf, params);
    buf.appendSlice(alloc, "}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Write a JSON-RPC 2.0 request (server → client).
fn writeRequest(s: *Session, id: i64, method: []const u8, params: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    var tmp: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&tmp, "{d}", .{id}) catch return;
    buf.appendSlice(alloc, id_str) catch return;
    buf.appendSlice(alloc, ",\"method\":\"") catch return;
    buf.appendSlice(alloc, method) catch return;
    buf.appendSlice(alloc, "\",\"params\":") catch return;
    buf.appendSlice(alloc, params) catch return;
    buf.appendSlice(alloc, "}\n") catch return;
    _ = s.stdout.write(buf.items) catch 0;
}

/// Append data to buf, skipping \n and \r characters.
/// Uses span-based batch copies instead of byte-by-byte append.
fn appendStrippingNewlines(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) {
        const start = i;
        while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
        if (i > start) buf.appendSlice(alloc, data[start..i]) catch return;
        if (i < data.len) i += 1; // skip the newline/cr
    }
}

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
