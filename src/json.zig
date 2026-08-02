// mcp-zig — JSON helpers
//
// Line reader, field extraction, JSON escaping.
// No external dependencies — pure std.

const std = @import("std");

pub const MAX_LINE = 1024 * 1024; // 1 MB

// ── Line reader ──────────────────────────────────────────────────────────────

/// Read one newline-terminated line via a buffered Io.Reader.
/// Caller owns the returned slice.  The reader retains leftover bytes
/// across calls, so a single read() syscall typically serves many lines.
pub fn readLineBuf(alloc: std.mem.Allocator, reader: *std.Io.Reader) ?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = reader.takeByte() catch {
            if (line.items.len == 0) { line.deinit(alloc); return null; }
            return line.toOwnedSlice(alloc) catch null;
        };
        if (byte == '\n') return line.toOwnedSlice(alloc) catch null;
        line.append(alloc, byte) catch { line.deinit(alloc); return null; };
        if (line.items.len > MAX_LINE) { line.deinit(alloc); return null; }
    }
}

/// Read one newline-terminated line into an existing ArrayList (clear + refill).
/// Avoids per-line allocation — the buffer grows once and is reused across calls.
/// Returns the filled slice, or null on EOF/error.
pub fn readLineInto(alloc: std.mem.Allocator, reader: *std.Io.Reader, buf: *std.ArrayList(u8)) ?[]u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch {
            if (buf.items.len == 0) return null;
            return buf.items;
        };
        if (byte == '\n') return buf.items;
        buf.append(alloc, byte) catch return null;
        if (buf.items.len > MAX_LINE) return null;
    }
}

// ── Fast JSON-RPC field scanner ──────────────────────────────────────────────

/// Result of scanning a JSON-RPC message for method and id without full parse.
/// Result of scanning a JSON-RPC message for method and id without full parse.
pub const ScanResult = struct {
    method: ?[]const u8 = null, // points into the source JSON
    id_raw: ?[]const u8 = null, // raw JSON fragment for id (e.g. "1" or "\"abc\"")
    params_raw: ?[]const u8 = null, // raw JSON of the params object (for tools/call fast path)
    meta_raw: ?[]const u8 = null, // raw JSON of the _meta object (top-level, else params._meta)
    has_result: bool = false,
    has_error: bool = false,
};

/// Fast scan of a JSON-RPC message to extract "method" and "id" fields
/// without building a JSON tree. Returns slices pointing into `data`.
/// O(n) single pass, zero allocations.
pub fn scanJsonRpc(data: []const u8) ScanResult {
    var result: ScanResult = .{};
    var i: usize = 0;

    while (i < data.len) {
        // Skip to next '"'
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1; // skip opening '"'

        // Read the key
        const key_start = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1; // skip escaped char
        }
        if (i >= data.len) break;
        const key = data[key_start..i];
        i += 1; // skip closing '"'

        // Skip ':'
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1; // skip ':'

        // Skip whitespace
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(key, "method")) {
            // Value must be a string
            if (data[i] == '"') {
                i += 1;
                const val_start = i;
                while (i < data.len and data[i] != '"') : (i += 1) {
                    if (data[i] == '\\') i += 1;
                }
                if (i < data.len) {
                    result.method = data[val_start..i];
                    i += 1;
                }
            }
        } else if (eql(key, "id")) {
            // Capture raw value: number, string, or null
            const val_start = i;
            if (data[i] == '"') {
                // String id
                i += 1;
                while (i < data.len and data[i] != '"') : (i += 1) {
                    if (data[i] == '\\') i += 1;
                }
                if (i < data.len) i += 1;
            } else {
                // Number or null — scan to next , or }
                while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
            }
            result.id_raw = std.mem.trim(u8, data[val_start..i], " \t");
        } else if (eql(key, "result")) {
            result.has_result = true;
            // Skip the value (we don't need it for dispatch)
            skipJsonValue(data, &i);
        } else if (eql(key, "error")) {
            result.has_error = true;
            skipJsonValue(data, &i);
        } else if (eql(key, "params")) {
            // Capture the raw params object as a slice
            const val_start = i;
            skipJsonValue(data, &i);
            // Malformed input can run the skip past the end — never panic on it.
            result.params_raw = data[val_start..@min(i, data.len)];
        } else if (eql(key, "_meta")) {
            // Capture a top-level raw _meta object as a slice
            const val_start = i;
            skipJsonValue(data, &i);
            result.meta_raw = data[val_start..@min(i, data.len)];
        } else {
            // Skip unknown value
            skipJsonValue(data, &i);
        }
    }
    // MCP 2026-07-28 carries versioning/client metadata in params._meta, which
    // the loop above skips over as part of the params value — fall back to a
    // targeted scan of the params slice.
    if (result.meta_raw == null) {
        if (result.params_raw) |p| result.meta_raw = scanObj(p, "_meta");
    }
    return result;
}

// ── MCP 2026-07-28 _meta keys ────────────────────────────────────────────────

pub const META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion";
pub const META_LOG_LEVEL = "io.modelcontextprotocol/logLevel";
pub const META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo";
pub const META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities";

/// Extract a string-valued _meta key (e.g. protocolVersion, logLevel).
pub fn metaStr(meta_raw: ?[]const u8, key: []const u8) ?[]const u8 {
    const m = meta_raw orelse return null;
    return scanStr(m, key);
}

/// Capture the raw JSON value for `key` — string (INCLUDING quotes), number,
/// bool, null, or object/array — so it can be echoed verbatim (e.g.
/// _meta.progressToken in notifications/progress).
pub fn scanValue(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(k, key)) {
            const vs = i;
            skipJsonValue(data, &i);
            return data[vs..@min(i, data.len)];
        }
        skipJsonValue(data, &i);
    }
    return null;
}

/// Extract the per-request protocol version a modern (2026-07-28) client
/// stamps into `_meta`, if any. Null means a legacy (pre-2026-07-28) request.
pub fn metaProtocolVersion(meta_raw: ?[]const u8) ?[]const u8 {
    return metaStr(meta_raw, META_PROTOCOL_VERSION);
}

/// Skip one JSON value starting at data[i*]. Advances i past the value.
fn skipJsonValue(data: []const u8, i: *usize) void {
    if (i.* >= data.len) return;
    switch (data[i.*]) {
        '"' => {
            i.* += 1;
            while (i.* < data.len and data[i.*] != '"') : (i.* += 1) {
                if (data[i.*] == '\\') i.* += 1;
            }
            if (i.* < data.len) i.* += 1;
        },
        '{' => {
            var depth: usize = 1;
            i.* += 1;
            while (i.* < data.len and depth > 0) : (i.* += 1) {
                switch (data[i.*]) {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    '"' => { // skip strings to avoid counting braces inside them
                        i.* += 1;
                        while (i.* < data.len and data[i.*] != '"') : (i.* += 1) {
                            if (data[i.*] == '\\') i.* += 1;
                        }
                    },
                    else => {},
                }
            }
        },
        '[' => {
            var depth: usize = 1;
            i.* += 1;
            while (i.* < data.len and depth > 0) : (i.* += 1) {
                switch (data[i.*]) {
                    '[' => depth += 1,
                    ']' => depth -= 1,
                    '"' => {
                        i.* += 1;
                        while (i.* < data.len and data[i.*] != '"') : (i.* += 1) {
                            if (data[i.*] == '\\') i.* += 1;
                        }
                    },
                    else => {},
                }
            }
        },
        else => {
            // number, bool, null — scan to delimiter
            while (i.* < data.len and data[i.*] != ',' and data[i.*] != '}' and data[i.*] != ']') : (i.* += 1) {}
        },
    }
}

// ── Raw JSON field extractors (zero-alloc) ───────────────────────────────────
//
// Extract values from a raw JSON object string without building a tree.
// Used by the tools/call fast path to avoid std.json.parseFromSlice entirely.

/// Extract a string value for `key` from a raw JSON object. Returns a slice into `data`.
pub fn scanStr(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(k, key)) {
            if (data[i] != '"') return null;
            i += 1;
            const vs = i;
            while (i < data.len and data[i] != '"') : (i += 1) {
                if (data[i] == '\\') i += 1;
            }
            if (i < data.len) return data[vs..i];
            return null;
        }
        skipJsonValue(data, &i);
    }
    return null;
}

/// Extract an integer value for `key` from a raw JSON object.
pub fn scanInt(data: []const u8, key: []const u8) ?i64 {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(k, key)) {
            const vs = i;
            while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
            const raw = std.mem.trim(u8, data[vs..i], " \t");
            return std.fmt.parseInt(i64, raw, 10) catch null;
        }
        skipJsonValue(data, &i);
    }
    return null;
}

/// Extract a raw JSON object value for `key` from a raw JSON object.
/// Returns the full `{...}` slice including braces.
pub fn scanObj(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(k, key)) {
            if (data[i] != '{') return null;
            const vs = i;
            skipJsonValue(data, &i);
            return data[vs..@min(i, data.len)];
        }
        skipJsonValue(data, &i);
    }
    return null;
}

/// Extract a boolean value for `key` from a raw JSON object.
pub fn scanBool(data: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
        if (i >= data.len) break;

        if (eql(k, key)) {
            if (i + 4 <= data.len and std.mem.eql(u8, data[i..][0..4], "true")) return true;
            return false;
        }
        skipJsonValue(data, &i);
    }
    return false;
}

/// Check if a key exists in a raw JSON object (value can be anything).
pub fn scanHasKey(data: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        while (i < data.len and data[i] != '"') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;
        const ks = i;
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) break;
        const k = data[ks..i];
        i += 1;
        while (i < data.len and data[i] != ':') : (i += 1) {}
        if (i >= data.len) break;
        i += 1;

        if (eql(k, key)) return true;
        skipJsonValue(data, &i);
    }
    return false;
}

/// Legacy API — reads one byte at a time from the raw file handle.
/// Prefer readLineBuf with a File.Reader for better performance.
pub fn readLine(alloc: std.mem.Allocator, io: std.Io, file: std.Io.File) ?[]u8 {
    var read_buf: [256]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    return readLineBuf(alloc, &reader.interface);
}

// ── Field extraction ──────────────────────────────────────────────────────────

pub fn getStr(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(obj: *const std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── JSON string escaping ──────────────────────────────────────────────────────

/// Append `s` to `out` with JSON string escaping applied.
/// Batch-copies runs of safe characters for performance.
/// Append `s` to `out` with JSON string escaping applied.
/// Uses SIMD (16-byte vectors) to scan for safe characters in bulk,
/// then batch-copies safe runs. Falls back to scalar for the tail.
pub fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    const Vec = @Vector(16, u8);
    var i: usize = 0;

    while (i < s.len) {
        const start = i;

        // SIMD fast scan: check 16 bytes at a time for characters needing escape
        while (i + 16 <= s.len) {
            const chunk: Vec = s[i..][0..16].*;
            // Characters needing escape: < 0x20, '"' (0x22), '\\' (0x5C)
            const lo = chunk < @as(Vec, @splat(@as(u8, 0x20)));
            const dq = chunk == @as(Vec, @splat(@as(u8, '"')));
            const bs = chunk == @as(Vec, @splat(@as(u8, '\\')));
            const need_esc = lo | dq | bs;
            if (@reduce(.Or, need_esc)) break; // found a char needing escape
            i += 16;
        }

        // Scalar scan for remaining bytes (< 16 or after SIMD found something)
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }

        // Batch-copy the safe run
        if (i > start) out.appendSlice(alloc, s[start..i]) catch return;
        if (i >= s.len) break;

        // Escape the special character
        const c = s[i];
        switch (c) {
            '"' => out.appendSlice(alloc, "\\\"") catch return,
            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            '\n' => out.appendSlice(alloc, "\\n") catch return,
            '\r' => out.appendSlice(alloc, "\\r") catch return,
            '\t' => out.appendSlice(alloc, "\\t") catch return,
            else => {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                out.appendSlice(alloc, &esc) catch return;
            },
        }
        i += 1;
    }
}

// ── Robustness property tests ────────────────────────────────────────────────

test "scanJsonRpc never panics on malformed input" {
    const testing = std.testing;
    _ = testing;
    const seed = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"x\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"progressToken\":\"t\"}}}";

    // Every truncation point.
    for (0..seed.len) |n| {
        _ = scanJsonRpc(seed[0..n]);
    }

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rng = prng.random();
    var buf: [512]u8 = undefined;

    // Random single-byte mutations.
    for (0..3000) |_| {
        const n = rng.uintLessThan(usize, seed.len) + 1;
        @memcpy(buf[0..n], seed[0..n]);
        buf[rng.uintLessThan(usize, n)] = rng.int(u8);
        _ = scanJsonRpc(buf[0..n]);
    }

    // Quote/backslash storms (historically the unterminated-string killers).
    for (0..2000) |_| {
        const n = rng.uintLessThan(usize, seed.len) + 1;
        @memcpy(buf[0..n], seed[0..n]);
        buf[rng.uintLessThan(usize, n)] = if (rng.boolean()) '"' else '\\';
        const r = scanJsonRpc(buf[0..n]);
        // Any captured slice must stay in-bounds.
        if (r.params_raw) |p| {
            const start = @intFromPtr(p.ptr) - @intFromPtr(buf[0..].ptr);
            try std.testing.expect(start + p.len <= n);
        }
        if (r.meta_raw) |m| {
            const start = @intFromPtr(m.ptr) - @intFromPtr(buf[0..].ptr);
            try std.testing.expect(start + m.len <= n);
        }
    }
}

test "scanValue captures raw JSON values verbatim" {
    const testing = std.testing;
    const meta = "{\"progressToken\":\"tok-1\",\"n\":42,\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}";
    try testing.expectEqualStrings("\"tok-1\"", scanValue(meta, "progressToken").?);
    try testing.expectEqualStrings("42", scanValue(meta, "n").?);
    try testing.expectEqualStrings("2026-07-28", scanStr(meta, "io.modelcontextprotocol/protocolVersion").?);
    try testing.expect(scanValue(meta, "missing") == null);
}

test "scanJsonRpc: ids, notifications, results, meta fallback" {
    const testing = std.testing;

    // number id
    var r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"}");
    try testing.expectEqualStrings("ping", r.method.?);
    try testing.expectEqualStrings("42", r.id_raw.?);

    // string id
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":\"abc-1\",\"method\":\"ping\"}");
    try testing.expectEqualStrings("\"abc-1\"", r.id_raw.?);

    // notification: no id
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}");
    try testing.expectEqualStrings("notifications/cancelled", r.method.?);
    try testing.expect(r.id_raw == null);

    // response detection
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
    try testing.expect(r.method == null);
    try testing.expect(r.has_result);
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601}}");
    try testing.expect(r.has_error);

    // params._meta fallback (top-level _meta absent)
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"k\":\"v\"}}}");
    try testing.expect(r.params_raw != null);
    try testing.expectEqualStrings("{\"k\":\"v\"}", r.meta_raw.?);

    // top-level _meta wins over params._meta
    r = scanJsonRpc("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":{\"_meta\":{\"a\":\"1\"}},\"_meta\":{\"b\":\"2\"}}");
    try testing.expectEqualStrings("{\"b\":\"2\"}", r.meta_raw.?);
}

test "scanStr/scanObj/scanBool/scanInt" {
    const testing = std.testing;
    const doc = "{\"name\":\"read\\\"file\",\"n\":-17,\"flag\":true,\"other\":false,\"obj\":{\"a\":1},\"arr\":[1,2]}";
    try testing.expectEqualStrings("read\\\"file", scanStr(doc, "name").?);
    try testing.expectEqual(@as(?i64, -17), scanInt(doc, "n"));
    try testing.expect(scanBool(doc, "flag"));
    try testing.expect(!scanBool(doc, "other"));
    try testing.expect(!scanBool(doc, "missing"));
    try testing.expectEqualStrings("{\"a\":1}", scanObj(doc, "obj").?);
    try testing.expect(scanStr(doc, "n") == null); // not a string
    try testing.expect(scanObj(doc, "arr") == null); // array, not object
}

test "getStr/getInt/getBool from ObjectMap" {
    const testing = std.testing;
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(testing.allocator);
    try args.put(testing.allocator, "s", .{ .string = "hello" });
    try args.put(testing.allocator, "i", .{ .integer = 7 });
    try args.put(testing.allocator, "b", .{ .bool = true });
    try testing.expectEqualStrings("hello", getStr(&args, "s").?);
    try testing.expect(getStr(&args, "i") == null);
    try testing.expectEqual(@as(?i64, 7), getInt(&args, "i"));
    try testing.expect(getInt(&args, "s") == null);
    try testing.expect(getBool(&args, "b"));
    try testing.expect(!getBool(&args, "missing"));
}

test "writeEscaped handles quotes, backslashes, newlines, controls" {
    const testing = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    writeEscaped(testing.allocator, &out, "a\"b\\c\nd\te\x01");
    try testing.expectEqualStrings("a\\\"b\\\\c\\nd\\te\\u0001", out.items);
}

test "metaStr and metaProtocolVersion" {
    const testing = std.testing;
    const meta = "{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/logLevel\":\"debug\"}";
    try testing.expectEqualStrings("debug", metaStr(meta, META_LOG_LEVEL).?);
    try testing.expectEqualStrings("2026-07-28", metaProtocolVersion(meta).?);
    try testing.expect(metaProtocolVersion(null) == null);
    try testing.expect(metaStr(null, META_LOG_LEVEL) == null);
}

test "readLineBuf and readLineInto basics" {
    const testing = std.testing;
    const data = "line one\nline two\n";
    var reader = std.Io.Reader.fixed(data);
    const l1 = readLineBuf(testing.allocator, &reader).?;
    defer testing.allocator.free(l1);
    try testing.expectEqualStrings("line one", l1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const l2 = readLineInto(testing.allocator, &reader, &buf).?;
    try testing.expectEqualStrings("line two", l2);
    try testing.expect(readLineInto(testing.allocator, &reader, &buf) == null);
}
