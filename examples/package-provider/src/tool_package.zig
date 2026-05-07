const std = @import("std");
const mcp_zig = @import("mcp");

const echo_schema =
    \\{"name":"example_echo","description":"Echo a message from an external package.","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}
;

fn echo(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const message = mcp_zig.json.getStr(args, "message") orelse {
        out.appendSlice(alloc, "error: missing 'message'") catch {};
        return;
    };

    out.appendSlice(alloc, message) catch {};
}

pub fn mcp() mcp_zig.registry.ToolPack {
    return mcp_zig.registry.pack(&.{.{
        .name = "example_echo",
        .handler = echo,
        .schema = echo_schema,
    }});
}
