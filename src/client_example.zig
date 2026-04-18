// mcp-zig — Client example
//
// Spawns the mcp-zig server and calls its read_file tool.
//
// Usage: zig build run-client -- /path/to/mcp-zig
//        or:  zig-out/bin/mcp-client /path/to/server

const std = @import("std");
const McpClient = @import("client.zig").McpClient;
const runtime = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    var rt = try runtime.Runtime.init(alloc, init);
    defer rt.deinit();
    const io = rt.io();

    const Io = std.Io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try stderr.print(
            \\mcp-client — MCP client example
            \\
            \\Usage: mcp-client <server-path> [tool-name] [args-json]
            \\
            \\Examples:
            \\  mcp-client ./zig-out/bin/mcp-zig
            \\  mcp-client ./zig-out/bin/mcp-zig read_file '{{"path":"README.md"}}'
            \\
        , .{});
        try stderr.flush();
        return;
    }

    const server_path = args[1];
    const tool_name = if (args.len > 2) args[2] else null;
    const tool_args = if (args.len > 3) args[3] else "{}";

    // Spawn server
    var client = try McpClient.init(alloc, io, &.{server_path}, null);
    defer client.deinit();

    // Initialize
    try stdout.print("→ initialize\n", .{});
    const init_result = try client.initialize();
    defer alloc.free(init_result);
    try stdout.print("← {s}\n\n", .{init_result});

    try client.notifyInitialized();

    // List tools
    try stdout.print("→ tools/list\n", .{});
    const tools_result = try client.listTools();
    defer alloc.free(tools_result);
    try stdout.print("← {s}\n\n", .{tools_result});

    // Call tool (if specified)
    if (tool_name) |name| {
        try stdout.print("→ tools/call: {s}({s})\n", .{ name, tool_args });
        const call_result = try client.callTool(name, tool_args);
        defer alloc.free(call_result);
        try stdout.print("← {s}\n", .{call_result});
    }

    // Ping
    try stdout.print("\n→ ping\n", .{});
    const alive = try client.ping();
    try stdout.print("← pong: {}\n", .{alive});
    try stdout.flush();
}
