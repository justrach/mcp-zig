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

/// Legacy API — reads one byte at a time from the raw file handle.
/// Prefer readLineBuf with a File.Reader for better performance.
pub fn readLine(alloc: std.mem.Allocator, file: std.fs.File) ?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    var buf: [1]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch {
            line.deinit(alloc);
            return null;
        };
        if (n == 0) {
            if (line.items.len == 0) { line.deinit(alloc); return null; }
            return line.toOwnedSlice(alloc) catch null;
        }
        if (buf[0] == '\n') return line.toOwnedSlice(alloc) catch null;
        line.append(alloc, buf[0]) catch { line.deinit(alloc); return null; };
        if (line.items.len > MAX_LINE) { line.deinit(alloc); return null; }
    }
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
pub fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }
        if (i > start) out.appendSlice(alloc, s[start..i]) catch return;
        if (i >= s.len) break;
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
