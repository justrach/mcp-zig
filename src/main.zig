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

pub fn main(init: std.process.Init) void {
    mcp.run(init.arena.allocator(), init.io);
}
