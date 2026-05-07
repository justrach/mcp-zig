// mcp-zig — public API
//
// Import this module to use mcp-zig as a library:
//
//   const mcp = @import("mcp");
//   const McpClient = mcp.client.McpClient;
//   const Registry = mcp.registry.Registry;
//   const wrapFn = mcp.registry.wrapFn;

const protocol = @import("mcp.zig");

pub const mcp = protocol;
pub const Server = protocol.Server;
pub const run = protocol.run;
pub const runWithRegistry = protocol.runWithRegistry;
pub const validateRegistry = protocol.validateRegistry;
pub const PROTOCOL_VERSION = protocol.PROTOCOL_VERSION;
pub const DEFAULT_INITIALIZE_RESULT = protocol.DEFAULT_INITIALIZE_RESULT;

pub const http = @import("http.zig");
pub const json = @import("json.zig");
pub const registry = @import("registry.zig");
pub const client = @import("client.zig");
pub const tools = @import("tools.zig");
