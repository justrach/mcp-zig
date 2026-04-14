// mcp-zig — Tool definitions
//
// THIS IS THE ONLY FILE YOU NEED TO EDIT to add new tools.
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
    // add_your_tool_here,
};

// ── Step 2: Tool schemas ────────────────────────────────────────────────────
//
// The `description` field is what the model reads to decide when/how to call
// the tool — be precise about what it does and what it returns.

pub const tools_list =
    \\{"tools":[
    \\{"name":"read_file","description":"Read a file from the filesystem and return its contents as text.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file"},"max_bytes":{"type":"integer","description":"Maximum bytes to read (default: 1MB)"}},"required":["path"]}},
    \\{"name":"list_dir","description":"List files and directories at a path.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Directory path to list (default: current directory)"}},"required":[]}}
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
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    switch (tool) {
        .read_file => handleReadFile(alloc, args, out),
        .list_dir  => handleListDir(alloc, args, out),
        // .add_your_tool_here => handleYourTool(alloc, args, out),
    }
}

/// Fast dispatch using raw JSON arguments (no std.json tree needed).
/// Extracts fields directly from the raw JSON string with zero allocations.
pub fn dispatchFast(
    alloc: std.mem.Allocator,
    tool: Tool,
    args_raw: []const u8,
    out: *std.ArrayList(u8),
) void {
    switch (tool) {
        .read_file => handleReadFileFast(alloc, args_raw, out),
        .list_dir  => handleListDirFast(alloc, args_raw, out),
    }
}

fn handleReadFileFast(alloc: std.mem.Allocator, args_raw: []const u8, out: *std.ArrayList(u8)) void {
    const path = json.scanStr(args_raw, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
    const max_bytes: usize = if (json.scanInt(args_raw, "max_bytes")) |n|
        @intCast(@max(1, n))
    else
        DEFAULT_MAX_BYTES;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch return;
        out.appendSlice(alloc, s) catch {};
        return;
    };
    defer file.close();

    out.ensureTotalCapacity(alloc, max_bytes) catch {
        out.appendSlice(alloc, "error: out of memory") catch {};
        return;
    };
    while (out.items.len < max_bytes) {
        const buf = out.unusedCapacitySlice();
        if (buf.len == 0) break;
        const n = file.read(buf) catch |err| {
            var tmp: [512]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "error reading '{s}': {s}", .{ path, @errorName(err) }) catch return;
            out.clearRetainingCapacity();
            out.appendSlice(alloc, s) catch {};
            return;
        };
        if (n == 0) break;
        out.items.len += n;
    }
}

fn handleListDirFast(alloc: std.mem.Allocator, args_raw: []const u8, out: *std.ArrayList(u8)) void {
    const path = json.scanStr(args_raw, "path") orelse ".";

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch return;
        out.appendSlice(alloc, s) catch {};
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .file      => 'f',
            .sym_link  => 'l',
            else       => '?',
        };
        var line: [std.fs.max_path_bytes + 4]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "{c} {s}\n", .{ kind, entry.name }) catch continue;
        out.appendSlice(alloc, s) catch {};
    }
}

// ── Handlers ──────────────────────────────────────────────────────────────────

const DEFAULT_MAX_BYTES = 1024 * 1024; // 1 MB

fn handleReadFile(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const path = json.getStr(args, "path") orelse {
        out.appendSlice(alloc, "error: missing 'path' argument") catch {};
        return;
    };
    const max_bytes: usize = if (json.getInt(args, "max_bytes")) |n|
        @intCast(@max(1, n))
    else
        DEFAULT_MAX_BYTES;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch return;
        out.appendSlice(alloc, s) catch {};
        return;
    };
    defer file.close();

    // Read directly into the output buffer to avoid a temporary allocation + copy.
    // Reserve space up front, then read into the unused tail of the ArrayList.
    out.ensureTotalCapacity(alloc, max_bytes) catch {
        out.appendSlice(alloc, "error: out of memory") catch {};
        return;
    };
    while (out.items.len < max_bytes) {
        const buf = out.unusedCapacitySlice();
        if (buf.len == 0) break;
        const n = file.read(buf) catch |err| {
            var tmp: [512]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "error reading '{s}': {s}", .{ path, @errorName(err) }) catch return;
            // Reset output, write error instead
            out.clearRetainingCapacity();
            out.appendSlice(alloc, s) catch {};
            return;
        };
        if (n == 0) break;
        out.items.len += n;
    }
}

fn handleListDir(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const path = json.getStr(args, "path") orelse ".";

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "error opening '{s}': {s}", .{ path, @errorName(err) }) catch return;
        out.appendSlice(alloc, s) catch {};
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .file      => 'f',
            .sym_link  => 'l',
            else       => '?',
        };
        var line: [std.fs.max_path_bytes + 4]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "{c} {s}\n", .{ kind, entry.name }) catch continue;
        out.appendSlice(alloc, s) catch {};
    }
}
