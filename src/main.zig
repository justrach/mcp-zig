// mcp-zig — entry point
//
// Runs the MCP server (JSON-RPC 2.0 over stdio).
// Register in ~/.claude.json:
//
//   "mcpServers": {
//     "my-server": {
//       "command": "/path/to/mcp-zig",
//       "args": []
//     }
//   }

const std = @import("std");
const mcp = @import("mcp.zig");

pub fn main() void {
    // Arena over page_allocator: one mmap up front, then O(1) bump allocation.
    // No per-allocation syscalls, no free overhead — ideal for a short-lived process.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    mcp.run(arena.allocator());
}
