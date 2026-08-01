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
const default_tools = @import("tools.zig");

pub const PROTOCOL_VERSION = "2025-06-18";

/// Newest protocol revision: the stateless ("Modern") spec — no initialize
/// handshake, per-request `_meta` versioning, mandatory `server/discover`.
pub const MODERN_PROTOCOL_VERSION = "2026-07-28";

/// Every version this implementation accepts, newest first. Advertised via
/// `server/discover` and used to validate modern per-request `_meta` versions.
/// Keep this conservative: only add a version once the core lifecycle/transport
/// behavior has been audited for that spec revision.
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    "2026-07-28",
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// Versions offered by the legacy initialize handshake, newest first.
/// 2026-07-28 is deliberately excluded: modern clients never call initialize,
/// so legacy negotiation must never clamp up to it.
pub const LEGACY_PROTOCOL_VERSIONS = [_][]const u8{
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// JSON-RPC error code for the 2026-07-28 UnsupportedProtocolVersionError.
pub const UNSUPPORTED_PROTOCOL_VERSION_CODE: i32 = -32022;

const DEFAULT_SERVER_INFO_OBJ = "{\"name\":\"mcp-zig\",\"title\":\"MCP Zig Server\",\"version\":\"1.0.0\"}";
const DEFAULT_CAPABILITIES_JSON = "{\"tools\":{\"listChanged\":false},\"logging\":{}}";
/// 2026-07-28 ServerCapabilities adds the `extensions` field (empty: this
/// server implements no extensions, e.g. io.modelcontextprotocol/tasks).
const MODERN_CAPABILITIES_JSON = "{\"tools\":{\"listChanged\":false},\"logging\":{},\"extensions\":{}}";
const DEFAULT_INSTRUCTIONS_TEXT = "MCP Zig server providing filesystem tools. Use read_file to read file contents and list_dir to list directory entries.";

/// `_meta` envelope stamped as the first key of every result for modern
/// (2026-07-28) requests, per the ResultMetaObject schema.
pub const MODERN_RESULT_META = "\"_meta\":{\"io.modelcontextprotocol/serverInfo\":" ++ DEFAULT_SERVER_INFO_OBJ ++ "}";

fn buildSupportedVersionsJson() []const u8 {
    comptime var out: []const u8 = "[";
    comptime {
        for (SUPPORTED_PROTOCOL_VERSIONS, 0..) |v, idx| {
            if (idx != 0) out = out ++ ",";
            out = out ++ "\"" ++ v ++ "\"";
        }
    }
    return out ++ "]";
}

/// `["2026-07-28","2025-11-25",...]` — comptime-joined from SUPPORTED_PROTOCOL_VERSIONS.
pub const SUPPORTED_VERSIONS_JSON = buildSupportedVersionsJson();

/// Default `server/discover` result (2026-07-28 DiscoverResult). Stateless:
/// requires no session and no initialize handshake. Registries may override
/// with `pub const discover_result = "{...}"`.
pub const DISCOVER_RESULT = "{\"resultType\":\"complete\",\"supportedVersions\":" ++ SUPPORTED_VERSIONS_JSON ++ ",\"capabilities\":" ++ MODERN_CAPABILITIES_JSON ++ ",\"ttlMs\":300000,\"cacheScope\":\"public\",\"instructions\":\"" ++ DEFAULT_INSTRUCTIONS_TEXT ++ "\"}";

/// Discover result for a registry: `discover_result` override wins, else default.
pub fn discoverResult(comptime Registry: type) []const u8 {
    validateRegistry(Registry);
    if (@hasDecl(Registry, "discover_result")) return Registry.discover_result;
    return DISCOVER_RESULT;
}

/// Membership check for modern per-request `_meta` protocol versions.
pub fn isSupportedProtocolVersion(v: []const u8) bool {
    for (SUPPORTED_PROTOCOL_VERSIONS) |sv| {
        if (std.mem.eql(u8, v, sv)) return true;
    }
    return false;
}

const DEFAULT_INITIALIZE_RESULT_PREFIX = "{\"protocolVersion\":\"";
const DEFAULT_INITIALIZE_RESULT_SUFFIX = "\",\"capabilities\":" ++ DEFAULT_CAPABILITIES_JSON ++ ",\"serverInfo\":" ++ DEFAULT_SERVER_INFO_OBJ ++ ",\"instructions\":\"" ++ DEFAULT_INSTRUCTIONS_TEXT ++ "\"}";

pub const DEFAULT_INITIALIZE_RESULT = DEFAULT_INITIALIZE_RESULT_PREFIX ++ PROTOCOL_VERSION ++ DEFAULT_INITIALIZE_RESULT_SUFFIX;

/// Validate that a tool registry provides the server-facing API.
pub fn validateRegistry(comptime Registry: type) void {
    if (!@hasDecl(Registry, "tools_list")) {
        @compileError("MCP registry " ++ @typeName(Registry) ++ " must expose pub const tools_list");
    }
    if (!@hasDecl(Registry, "parse")) {
        @compileError("MCP registry " ++ @typeName(Registry) ++ " must expose pub fn parse(name: []const u8)");
    }
    if (!@hasDecl(Registry, "dispatchFast")) {
        @compileError("MCP registry " ++ @typeName(Registry) ++ " must expose pub fn dispatchFast(alloc, io, tool, args_raw, out)");
    }
}

/// Return the initialize result JSON for a registry.
/// Registries may override server metadata/instructions with
/// `pub const initialize_result = "{...}"`.
pub fn initializeResult(comptime Registry: type) []const u8 {
    validateRegistry(Registry);
    if (@hasDecl(Registry, "initialize_result")) return Registry.initialize_result;
    return DEFAULT_INITIALIZE_RESULT;
}

/// Pick the protocol version to send back in initialize.
///
/// If the client requested a known version, echo it back. If it requested a
/// future date-like version, return our latest supported version. If it
/// requested an older/unknown version, return our oldest supported version so
/// older clients get the most compatible response shape.
pub fn negotiateProtocolVersion(requested: ?[]const u8) []const u8 {
    const req = requested orelse return PROTOCOL_VERSION;
    if (req.len == 0) return PROTOCOL_VERSION;

    for (LEGACY_PROTOCOL_VERSIONS) |v| {
        if (std.mem.eql(u8, req, v)) return v;
    }

    if (std.mem.order(u8, req, LEGACY_PROTOCOL_VERSIONS[0]) == .gt) {
        return LEGACY_PROTOCOL_VERSIONS[0];
    }
    return LEGACY_PROTOCOL_VERSIONS[LEGACY_PROTOCOL_VERSIONS.len - 1];
}

/// Build the default initialize result for a negotiated protocol version.
/// Caller owns the returned slice.
pub fn defaultInitializeResultForVersionAlloc(alloc: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        DEFAULT_INITIALIZE_RESULT_PREFIX,
        version,
        DEFAULT_INITIALIZE_RESULT_SUFFIX,
    });
}

/// Build the initialize result for a registry. Registries with a raw
/// `initialize_result` keep full control and are returned verbatim; otherwise
/// the default result is generated with the negotiated protocol version.
pub fn initializeResultForVersionAlloc(comptime Registry: type, alloc: std.mem.Allocator, version: []const u8) ![]u8 {
    validateRegistry(Registry);
    if (@hasDecl(Registry, "initialize_result")) return alloc.dupe(u8, Registry.initialize_result);
    return defaultInitializeResultForVersionAlloc(alloc, version);
}

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
    return std.meta.stringToEnum(LogLevel, s);
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
    io: std.Io,
    stdout: std.Io.File,
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

    // Modern (2026-07-28) mode for the in-flight request: stamp results with
    // the _meta serverInfo envelope. Reset per request in the read loop.
    stamp_meta: bool = false,

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

/// Server factory for downstream apps that provide their own tool registry.
pub fn Server(comptime Registry: type) type {
    validateRegistry(Registry);
    return struct {
        pub fn run(alloc: std.mem.Allocator, io: std.Io) void {
            runWithRegistry(alloc, io, Registry);
        }
    };
}

/// Run the default template server with the built-in filesystem tools.
pub fn run(alloc: std.mem.Allocator, io: std.Io) void {
    runWithRegistry(alloc, io, default_tools);
}

/// Run an MCP stdio server with an externally supplied tool registry.
pub fn runWithRegistry(alloc: std.mem.Allocator, io: std.Io, comptime Registry: type) void {
    validateRegistry(Registry);

    var session: Session = .{
        .alloc = alloc,
        .io = io,
        .stdout = std.Io.File.stdout(),
    };
    defer session.deinit();
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &read_buf);

    // Comptime perfect-hash method dispatch table — O(1) lookup, no sequential string comparisons.
    const Method = enum { ping, tools_list, tools_call, initialize, logging_setLevel, notif_initialized, notif_roots_changed, notif_cancelled, server_discover, subscriptions_listen };
    const method_map = std.StaticStringMap(Method).initComptime(.{
        .{ "ping", .ping },
        .{ "tools/list", .tools_list },
        .{ "tools/call", .tools_call },
        .{ "initialize", .initialize },
        .{ "logging/setLevel", .logging_setLevel },
        .{ "notifications/initialized", .notif_initialized },
        .{ "notifications/roots/list_changed", .notif_roots_changed },
        .{ "notifications/cancelled", .notif_cancelled },
        .{ "server/discover", .server_discover },
        .{ "subscriptions/listen", .subscriptions_listen },
    });

    while (true) {
        const line = json.readLineInto(alloc, &stdin_reader.interface, &session.line_buf) orelse break;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        const scan = json.scanJsonRpc(input);

        // 2026-07-28 modern gate: a request carrying _meta.protocolVersion opts
        // into stateless mode. Unknown versions get the spec-mandated
        // UnsupportedProtocolVersionError; known versions get _meta-stamped results.
        session.stamp_meta = false;
        if (json.metaProtocolVersion(scan.meta_raw)) |v| {
            if (!isSupportedProtocolVersion(v)) {
                writeUnsupportedProtocolVersion(&session, scan.id_raw, v);
                continue;
            }
            session.stamp_meta = true;
            // Per-request log-level opt-in (replaces legacy logging/setLevel).
            if (json.metaStr(scan.meta_raw, json.META_LOG_LEVEL)) |lvl| {
                session.log_level = logLevelFromString(lvl) orelse session.log_level;
            }
        }

        if (scan.method) |method| {
            // 2026-07-28 removes the handshake and these utilities; modern
            // callers get method-not-found (all remain for legacy clients).
            if (session.stamp_meta) {
                const modern_removed = std.StaticStringMap(void).initComptime(.{
                    .{ "initialize", {} },
                    .{ "notifications/initialized", {} },
                    .{ "ping", {} },
                    .{ "logging/setLevel", {} },
                    .{ "notifications/roots/list_changed", {} },
                });
                if (modern_removed.has(method)) {
                    if (scan.id_raw != null) writeErrorRaw(&session, scan.id_raw, -32601, "Method not found");
                    continue;
                }
            }
            if (method_map.get(method)) |m| switch (m) {
                // Fast path: no JSON parse needed — zero allocations
                .ping => writeResultRaw(&session, scan.id_raw, "{}"),
                .tools_list => writeToolsListResult(Registry, &session, scan.id_raw),
                .notif_initialized => { if (session.client_supports_roots) requestRoots(&session); },
                .notif_roots_changed => { if (session.client_supports_roots) requestRoots(&session); },
                .notif_cancelled => {},

                // tools/call: scanner-based fast path (no std.json parse)
                .tools_call => handleCall(Registry, &session, &scan),

                // initialize + logging/setLevel: scanner-based (no std.json parse)
                .initialize => handleInitializeFast(Registry, &session, &scan),
                .logging_setLevel => handleSetLogLevelFast(&session, &scan),

                // 2026-07-28: stateless discovery — always _meta-stamped
                .server_discover => {
                    session.stamp_meta = true;
                    writeResultRaw(&session, scan.id_raw, discoverResult(Registry));
                },

                // 2026-07-28: opt-in notification stream. This server has no
                // listChanged/update sources, so the acknowledged filter is
                // stored implicitly (no notifications are ever emitted — which
                // trivially satisfies "MUST NOT send unrequested types").
                .subscriptions_listen => {
                    const params_raw = scan.params_raw orelse {
                        writeErrorRaw(&session, scan.id_raw, -32602, "Missing params"); continue;
                    };
                    if (json.scanObj(params_raw, "notifications") == null) {
                        writeErrorRaw(&session, scan.id_raw, -32602, "Missing notifications filter"); continue;
                    }
                    session.stamp_meta = true; // SubscriptionsListenResult requires _meta
                    writeResultRaw(&session, scan.id_raw, "{\"resultType\":\"complete\"}");
                },
            } else {
                if (scan.id_raw != null) writeErrorRaw(&session, scan.id_raw, -32601, "Method not found");
            }
        } else if (scan.has_result or scan.has_error) {
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

fn handleCall(
    comptime Registry: type,
    s: *Session,
    scan: *const json.ScanResult,
) void {
    const alloc = s.alloc;
    const id_raw = scan.id_raw;

    // Extract tool name and arguments from raw params using scanner (no JSON tree parse)
    const params_raw = scan.params_raw orelse {
        writeErrorRaw(s, id_raw, -32602, "Missing params"); return;
    };
    const name = json.scanStr(params_raw, "name") orelse {
        writeErrorRaw(s, id_raw, -32602, "Missing tool name"); return;
    };
    const args_raw = json.scanObj(params_raw, "arguments") orelse {
        writeErrorRaw(s, id_raw, -32602, "Missing arguments"); return;
    };

    // Dispatch
    const tool = Registry.parse(name) orelse {
        writeErrorRaw(s, id_raw, -32602, "Unknown tool"); return;
    };

    // Run handler into reusable tool_buf (clear, not free).
    // Registries may expose dispatchFastOk to report handler failure — it
    // feeds the result's `isError` flag; absent the hook, assume success.
    s.tool_buf.clearRetainingCapacity();
    const tool_ok = if (@hasDecl(Registry, "dispatchFastOk"))
        Registry.dispatchFastOk(alloc, s.io, tool, args_raw, &s.tool_buf)
    else blk: {
        Registry.dispatchFast(alloc, s.io, tool, args_raw, &s.tool_buf);
        break :blk true;
    };

    // Build the complete JSON-RPC response directly into write_buf.
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.ensureTotalCapacity(alloc, 120 + s.tool_buf.items.len * 2) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(alloc, id_raw orelse "null") catch return;
    buf.appendSlice(alloc, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"") catch return;
    json.writeEscaped(alloc, buf, s.tool_buf.items);
    buf.appendSlice(alloc, "\"}],\"isError\":") catch return;
    buf.appendSlice(alloc, if (tool_ok) "false" else "true") catch return;

    // If output looks like a JSON object, include as structuredContent
    if (s.tool_buf.items.len > 0 and s.tool_buf.items[0] == '{') {
        if (isValidJsonObject(s.tool_buf.items)) {
            buf.appendSlice(alloc, ",\"structuredContent\":") catch return;
            buf.appendSlice(alloc, s.tool_buf.items) catch return;
        }
    }

    if (s.stamp_meta) {
        // 2026-07-28 CallToolResult requires resultType.
        buf.appendSlice(alloc, ",\"resultType\":\"complete\"," ++ MODERN_RESULT_META) catch return;
    }

    buf.appendSlice(alloc, "}}\n") catch return;
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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

    const requested_version = blk: {
        const p = root.get("params") orelse break :blk null;
        if (p != .object) break :blk null;
        break :blk json.getStr(&p.object, "protocolVersion");
    };
    const negotiated = negotiateProtocolVersion(requested_version);
    const init_result = defaultInitializeResultForVersionAlloc(s.alloc, negotiated) catch return;
    defer s.alloc.free(init_result);

    // (#5) instructions + (#3) logging capability
    writeResult(s, id, init_result);
}

/// Scanner-based initialize — no std.json parse needed.
fn handleInitializeFast(comptime Registry: type, s: *Session, scan: *const json.ScanResult) void {
    var requested_version: ?[]const u8 = null;
    if (scan.params_raw) |params_raw| {
        requested_version = json.scanStr(params_raw, "protocolVersion");
        if (json.scanObj(params_raw, "capabilities")) |caps| {
            if (json.scanObj(caps, "roots")) |roots| {
                s.client_supports_roots = true;
                s.client_roots_list_changed = json.scanBool(roots, "listChanged");
            }
        }
    }
    const negotiated = negotiateProtocolVersion(requested_version);
    const init_result = initializeResultForVersionAlloc(Registry, s.alloc, negotiated) catch return;
    defer s.alloc.free(init_result);
    writeResultRaw(s, scan.id_raw, init_result);
}

// ── logging (#3) ───────────────────────────────────────────────────────────

/// Scanner-based setLevel — no std.json parse needed.
fn handleSetLogLevelFast(s: *Session, scan: *const json.ScanResult) void {
    if (scan.params_raw) |params_raw| {
        if (json.scanStr(params_raw, "level")) |level_str| {
            s.log_level = logLevelFromString(level_str) orelse s.log_level;
        }
    }
    writeResultRaw(s, scan.id_raw, "{}");
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
    appendResultValue(alloc, buf, result, s.stamp_meta);
    buf.appendSlice(alloc, "}\n") catch return;
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
}

/// tools/list result. Modern (2026-07-28) ListToolsResult additionally
/// requires `resultType`, `ttlMs`, and `cacheScope` — injected here alongside
/// the `_meta` serverInfo envelope. Legacy responses are byte-identical.
fn writeToolsListResult(comptime Registry: type, s: *Session, id_raw: ?[]const u8) void {
    if (!s.stamp_meta) {
        writeResultRaw(s, id_raw, Registry.tools_list);
        return;
    }
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(alloc, id_raw orelse "null") catch return;
    buf.appendSlice(alloc, ",\"result\":{" ++ MODERN_RESULT_META ++ ",\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"public\",") catch return;
    // Registry.tools_list is '{"tools":[...]}' — splice in after the '{'.
    appendStrippingNewlines(alloc, buf, Registry.tools_list[1..]);
    buf.appendSlice(alloc, "}\n") catch return;
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
}

/// Append a `"result"` value, injecting the modern (2026-07-28) `_meta`
/// serverInfo envelope as the first key when `stamp` is set. `result` must be
/// a JSON object; anything else is appended verbatim.
fn appendResultValue(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), result: []const u8, stamp: bool) void {
    if (!stamp or result.len < 2 or result[0] != '{') {
        appendStrippingNewlines(alloc, buf, result);
        return;
    }
    buf.appendSlice(alloc, "{" ++ MODERN_RESULT_META) catch return;
    if (result[1] == '}') {
        buf.appendSlice(alloc, "}") catch return;
        return;
    }
    buf.appendSlice(alloc, ",") catch return;
    appendStrippingNewlines(alloc, buf, result[1..]);
}

/// 2026-07-28 UnsupportedProtocolVersionError: code -32022 with
/// `data: { requested, supported }` so the client can pick a version and retry.
fn writeUnsupportedProtocolVersion(s: *Session, id_raw: ?[]const u8, requested: []const u8) void {
    const alloc = s.alloc;
    const buf = &s.write_buf;
    buf.clearRetainingCapacity();
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    buf.appendSlice(alloc, id_raw orelse "null") catch return;
    buf.appendSlice(alloc, ",\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":\"") catch return;
    json.writeEscaped(alloc, buf, requested);
    buf.appendSlice(alloc, "\",\"supported\":" ++ SUPPORTED_VERSIONS_JSON ++ "}}}\n") catch return;
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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
    s.stdout.writeStreamingAll(s.io, buf.items) catch {};
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

test "negotiateProtocolVersion echoes known versions" {
    const testing = std.testing;
    try testing.expectEqualStrings("2025-11-25", negotiateProtocolVersion("2025-11-25"));
    try testing.expectEqualStrings("2025-06-18", negotiateProtocolVersion("2025-06-18"));
    try testing.expectEqualStrings("2025-03-26", negotiateProtocolVersion("2025-03-26"));
    try testing.expectEqualStrings("2024-11-05", negotiateProtocolVersion("2024-11-05"));
}

test "negotiateProtocolVersion handles absent and unknown versions" {
    const testing = std.testing;
    try testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(null));
    try testing.expectEqualStrings(PROTOCOL_VERSION, negotiateProtocolVersion(""));
    // Modern versions are never offered by the legacy initialize handshake.
    try testing.expectEqualStrings("2025-11-25", negotiateProtocolVersion("2026-07-28"));
    try testing.expectEqualStrings("2025-11-25", negotiateProtocolVersion("2099-01-01"));
    try testing.expectEqualStrings("2024-11-05", negotiateProtocolVersion("2024-01-01"));
}

test "isSupportedProtocolVersion covers modern and legacy" {
    const testing = std.testing;
    try testing.expect(isSupportedProtocolVersion("2026-07-28"));
    try testing.expect(isSupportedProtocolVersion("2025-11-25"));
    try testing.expect(isSupportedProtocolVersion("2025-06-18"));
    try testing.expect(!isSupportedProtocolVersion("2099-01-01"));
    try testing.expect(!isSupportedProtocolVersion(""));
}

test "discover result advertises all supported versions" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, DISCOVER_RESULT, "\"resultType\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, DISCOVER_RESULT, "\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\",\"2024-11-05\"]") != null);
    try testing.expect(std.mem.indexOf(u8, DISCOVER_RESULT, "\"cacheScope\":\"public\"") != null);
    try testing.expect(std.mem.indexOf(u8, DISCOVER_RESULT, "\"ttlMs\":300000") != null);
}

test "defaultInitializeResultForVersionAlloc uses negotiated version" {
    const testing = std.testing;
    const result = try defaultInitializeResultForVersionAlloc(testing.allocator, "2025-03-26");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"protocolVersion\":\"2025-03-26\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"serverInfo\"") != null);
}
