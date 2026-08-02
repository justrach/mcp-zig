// mcp-zig — entry point
//
// Runs the MCP server (JSON-RPC 2.0 over stdio by default, or HTTP with
// `--http [host:port]`).
// Register in ~/.claude.json:
//
//   "mcpServers": {
//     "my-server": {
//       "command": "/path/to/mcp-zig",
//       "args": []
//     }
//   }

const std = @import("std");
const http = @import("http.zig");
const mcp = @import("mcp.zig");
const runtime = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    var rt = try runtime.Runtime.init(init.gpa, init);
    defer rt.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--http")) {
            const endpoint = args.next() orelse "127.0.0.1:8000";
            var opts = try parseHttpEndpoint(endpoint);
            if (args.next()) |maybe_auth| {
                if (std.mem.startsWith(u8, maybe_auth, "--auth-secret=")) {
                    opts.auth = .{ .hs256_secret = maybe_auth["--auth-secret=".len..] };
                }
            }
            try http.serve(rt.io(), init.gpa, opts);
            return;
        }
        if (std.mem.startsWith(u8, arg, "--http=")) {
            var opts = try parseHttpEndpoint(arg["--http=".len..]);
            if (args.next()) |maybe_auth| {
                if (std.mem.startsWith(u8, maybe_auth, "--auth-secret=")) {
                    opts.auth = .{ .hs256_secret = maybe_auth["--auth-secret=".len..] };
                }
            }
            try http.serve(rt.io(), init.gpa, opts);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage(rt.io());
            return;
        }
    }

    mcp.run(init.arena.allocator(), rt.io());
}

fn parseHttpEndpoint(raw: []const u8) !http.Options {
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

fn usage(io: std.Io) !void {
    const msg =
        \\mcp-zig
        \\
        \\Usage:
        \\  mcp-zig                         Run MCP over stdio
        \\  mcp-zig --http [host:port]      Run MCP over HTTP POST /mcp
        \\  mcp-zig --http=127.0.0.1:8000  Run MCP over HTTP POST /mcp
        \\
    ;
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}
