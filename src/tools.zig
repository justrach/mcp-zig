// mcp-zig — Tool definitions
//
// When using this repo as a template, this is the only file you need to edit to add new tools.
//
// Four steps:
//   1. Add the tool name to the `Tool` enum
//   2. Add its JSON Schema to `tools_list`
//   3. Add a branch in `dispatch`
//   4. Write the handler function
//
// Handlers receive the parsed JSON args and write their result to `out`.
// Whatever you write to `out` becomes the tool response text shown to the model.

const std = @import("std");
const json = @import("json.zig");

// ── Step 1: Tool enum ─────────────────────────────────────────────────────────

pub const Tool = enum {
    read_file,
    list_dir,
    batch,
    // add_your_tool_here,
};

// ── Step 2: Tool schemas ────────────────────────────────────────────────────
//
// The `description` field is what the model reads to decide when/how to call
// the tool — be precise about what it does and what it returns.

pub const tools_list =
    \\{"tools":[
    \\{"name":"read_file","title":"Read File","description":"Read a file from the filesystem and return its contents as text.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file"},"max_bytes":{"type":"integer","description":"Maximum bytes to read (default: 1MB)"}},"required":["path"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}},
    \\{"name":"list_dir","title":"List Directory","description":"List files and directories at a path.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list (default: current directory)"}},"required":[]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}},
    \\{"name":"batch","title":"Batch Operations","description":"Run multiple read_file or list_dir operations in one tool call and return ordered per-item results.","inputSchema":{"type":"object","properties":{"operations":{"type":"array","description":"Operations to execute in order.","items":{"type":"object","properties":{"tool":{"type":"string","enum":["read_file","list_dir"],"description":"Nested tool to execute."},"arguments":{"type":"object","description":"Arguments for the nested tool."}},"required":["tool","arguments"]}}},"required":["operations"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}}
    \\]}
;

// ── Step 3: Parser ──────────────────────────────────────────────────────────────
//
// std.meta.stringToEnum generates a comptime switch — zero runtime overhead.

pub fn parse(name: []const u8) ?Tool {
    return std.meta.stringToEnum(Tool, name);
}

// ── Step 4: Dispatch ──────────────────────────────────────────────────────────

pub fn dispatch(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = dispatchResult(alloc, io, tool, args, out);
}

/// Fast dispatch using raw JSON arguments (no std.json tree needed).
/// Extracts fields directly from the raw JSON string with zero allocations.
pub fn dispatchFast(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: Tool,
    args_raw: []const u8,
    out: *std.ArrayList(u8),
) void {
    _ = dispatchFastOk(alloc, io, tool, args_raw, out);
}

/// `dispatchFast` variant that reports handler success, so transports can set
/// `isError` on tool results (2025-11-25 conformance).
pub fn dispatchFastOk(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: Tool,
    args_raw: []const u8,
    out: *std.ArrayList(u8),
) bool {
    return dispatchFastResult(alloc, io, tool, args_raw, out);
}

fn dispatchResult(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) bool {
    return switch (tool) {
        .read_file => handleReadFile(alloc, io, args, out),
        .list_dir  => handleListDir(alloc, io, args, out),
        .batch     => handleBatch(alloc, io, args, out),
    };
}

fn dispatchFastResult(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: Tool,
    args_raw: []const u8,
    out: *std.ArrayList(u8),
) bool {
    return switch (tool) {
        .read_file => handleReadFileFast(alloc, io, args_raw, out),
        .list_dir  => handleListDirFast(alloc, io, args_raw, out),
        .batch     => handleBatchFast(alloc, io, args_raw, out),
    };
}

fn appendFileContents(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
    out: *std.ArrayList(u8),
) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch "error opening file";
        out.appendSlice(alloc, s) catch {};
        return false;
    };
    defer file.close(io);

    const reserve_len = blk: {
        const stat = file.stat(io) catch break :blk max_bytes;
        break :blk @min(max_bytes, std.math.cast(usize, stat.size) orelse max_bytes);
    };

    const start = out.items.len;
    out.ensureUnusedCapacity(alloc, reserve_len) catch {
        out.appendSlice(alloc, "error: out of memory") catch {};
        return false;
    };
    out.items.len += reserve_len;

    const n = file.readPositionalAll(io, out.items[start..], 0) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error reading '{s}': {s}", .{ path, @errorName(err) }) catch "error reading file";
        out.items.len = start;
        out.appendSlice(alloc, s) catch {};
        return false;
    };
    out.items.len = start + n;
    return true;
}

fn appendDirEntries(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayList(u8),
) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch "error opening directory";
        out.appendSlice(alloc, s) catch {};
        return false;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .file      => 'f',
            .sym_link  => 'l',
            else       => '?',
        };
        var line: [std.Io.Dir.max_path_bytes + 4]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "{c} {s}\n", .{ kind, entry.name }) catch continue;
        out.appendSlice(alloc, s) catch return false;
    }
    return true;
}

fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(alloc, '"') catch return;
    json.writeEscaped(alloc, out, s);
    out.append(alloc, '"') catch return;
}

fn appendBatchTopLevelError(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) bool {
    out.appendSlice(alloc, "{\"results\":[],\"error\":") catch return false;
    appendJsonString(alloc, out, msg);
    out.append(alloc, '}') catch return false;
    return false;
}

fn appendBatchResult(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    index: usize,
    tool_name: ?[]const u8,
    ok: bool,
    payload: []const u8,
) void {
    var num_buf: [20]u8 = undefined;
    const index_str = std.fmt.bufPrint(&num_buf, "{d}", .{index}) catch return;

    out.appendSlice(alloc, "{\"index\":") catch return;
    out.appendSlice(alloc, index_str) catch return;
    out.appendSlice(alloc, ",\"tool\":") catch return;
    if (tool_name) |name| {
        appendJsonString(alloc, out, name);
    } else {
        out.appendSlice(alloc, "null") catch return;
    }
    out.appendSlice(alloc, ",\"ok\":") catch return;
    out.appendSlice(alloc, if (ok) "true" else "false") catch return;
    out.appendSlice(alloc, if (ok) ",\"text\":" else ",\"error\":") catch return;
    appendJsonString(alloc, out, payload);
    out.append(alloc, '}') catch return;
}

fn handleBatchFast(
    alloc: std.mem.Allocator,
    io: std.Io,
    args_raw: []const u8,
    out: *std.ArrayList(u8),
) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), args_raw, .{}) catch {
        return appendBatchTopLevelError(alloc, out, "invalid batch arguments");
    };

    if (parsed.value != .object) {
        return appendBatchTopLevelError(alloc, out, "batch arguments must be an object");
    }

    return handleBatch(alloc, io, &parsed.value.object, out);
}

fn handleBatch(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) bool {
    const operations_val = args.get("operations") orelse {
        return appendBatchTopLevelError(alloc, out, "missing 'operations' argument");
    };
    if (operations_val != .array) {
        return appendBatchTopLevelError(alloc, out, "'operations' must be an array");
    }

    var item_buf: std.ArrayList(u8) = .empty;
    defer item_buf.deinit(std.heap.page_allocator);

    out.appendSlice(alloc, "{\"results\":[") catch return false;

    for (operations_val.array.items, 0..) |op_val, index| {
        if (index != 0) out.append(alloc, ',') catch return false;

        if (op_val != .object) {
            appendBatchResult(alloc, out, index, null, false, "operation must be an object");
            continue;
        }

        var op_obj = op_val.object;
        const tool_name = json.getStr(&op_obj, "tool") orelse {
            appendBatchResult(alloc, out, index, null, false, "missing 'tool'");
            continue;
        };
        const nested_tool = parse(tool_name) orelse {
            appendBatchResult(alloc, out, index, tool_name, false, "unknown tool");
            continue;
        };
        if (nested_tool == .batch) {
            appendBatchResult(alloc, out, index, tool_name, false, "nested batch is not supported");
            continue;
        }

        const nested_args_val = op_obj.get("arguments") orelse {
            appendBatchResult(alloc, out, index, tool_name, false, "missing 'arguments'");
            continue;
        };
        if (nested_args_val != .object) {
            appendBatchResult(alloc, out, index, tool_name, false, "'arguments' must be an object");
            continue;
        }

        item_buf.clearRetainingCapacity();
        const ok = dispatchResult(std.heap.page_allocator, io, nested_tool, &nested_args_val.object, &item_buf);
        appendBatchResult(alloc, out, index, tool_name, ok, item_buf.items);
    }

    out.appendSlice(alloc, "]}") catch return false;
    return true;
}

fn handleReadFileFast(alloc: std.mem.Allocator, io: std.Io, args_raw: []const u8, out: *std.ArrayList(u8)) bool {
    const path = json.scanStr(args_raw, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return false;
    };
    const max_bytes: usize = if (json.scanInt(args_raw, "max_bytes")) |n|
        @intCast(@max(1, n))
    else
        DEFAULT_MAX_BYTES;

    return appendFileContents(alloc, io, path, max_bytes, out);
}

fn handleListDirFast(alloc: std.mem.Allocator, io: std.Io, args_raw: []const u8, out: *std.ArrayList(u8)) bool {
    const path = json.scanStr(args_raw, "path") orelse ".";
    return appendDirEntries(alloc, io, path, out);
}

// ── Handlers ──────────────────────────────────────────────────────────────────

const DEFAULT_MAX_BYTES = 1024 * 1024; // 1 MB

fn handleReadFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) bool {
    const path = json.getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return false;
    };
    const max_bytes: usize = if (json.getInt(args, "max_bytes")) |n|
        @intCast(@max(1, n))
    else
        DEFAULT_MAX_BYTES;

    return appendFileContents(alloc, io, path, max_bytes, out);
}

fn handleListDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) bool {
    const path = json.getStr(args, "path") orelse ".";
    return appendDirEntries(alloc, io, path, out);
}
