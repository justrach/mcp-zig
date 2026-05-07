const std = @import("std");
const mcp = @import("mcp");
const example_tools = @import("example_tools");

const Registry = mcp.registry.fromPackages(.{example_tools});

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--http")) {
        const opts: mcp.http.Options = if (args.len >= 3)
            try parseHttpEndpoint(args[2])
        else
            .{};
        try mcp.http.serveWithRegistry(init.io, init.gpa, opts, Registry);
        return;
    }

    mcp.runWithRegistry(init.arena.allocator(), init.io, Registry);
}

fn parseHttpEndpoint(raw: []const u8) !mcp.http.Options {
    if (raw.len == 0) return .{};

    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
        const host = raw[0..colon];
        const port_raw = raw[colon + 1 ..];
        return .{
            .host = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host,
            .port = try std.fmt.parseInt(u16, port_raw, 10),
        };
    }

    return .{
        .host = "127.0.0.1",
        .port = try std.fmt.parseInt(u16, raw, 10),
    };
}
