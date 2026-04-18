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
const runtime = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    var rt = try runtime.Runtime.init(init.gpa, init);
    defer rt.deinit();

    mcp.run(init.arena.allocator(), rt.io());
}
