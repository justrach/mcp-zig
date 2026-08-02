// kv-store cookbook — turn a tiny Zig product into an MCP server.
//
// The "product" is an in-memory key-value store with plain Zig functions.
// `mcp.registry.tool` wraps each function AND generates its JSON Schema at
// comptime — no hand-written schemas, no MCP boilerplate in the product code.
//
// Run:  zig build cookbook
// Then: printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"kv_set","arguments":{"key":"lang","value":"zig"}}}\n' | ./zig-out/bin/mcp-kv-store
//
// The same registry works over HTTP (see src/http.zig serveWithRegistry) and
// speaks both legacy MCP (initialize handshake) and modern 2026-07-28
// (stateless, _meta-versioned requests) with no code changes here.

const std = @import("std");
const mcp = @import("mcp");

// ── The product: plain Zig, zero MCP imports ────────────────────────────────

var store: ?std.StringHashMapUnmanaged([]const u8) = null;

fn storePtr(alloc: std.mem.Allocator) *std.StringHashMapUnmanaged([]const u8) {
    if (store == null) store = .empty;
    _ = alloc;
    return &store.?;
}

fn kvSet(alloc: std.mem.Allocator, key: []const u8, value: []const u8) ![]const u8 {
    const k = try alloc.dupe(u8, key);
    const v = try alloc.dupe(u8, value);
    try storePtr(alloc).put(alloc, k, v);
    return "ok";
}

fn kvGet(key: []const u8) []const u8 {
    const s = store orelse return "(not found)";
    return s.get(key) orelse "(not found)";
}

fn kvDelete(key: []const u8) []const u8 {
    const s = &(store orelse return "(not found)");
    return if (s.remove(key)) "deleted" else "(not found)";
}

fn kvCount() i64 {
    const s = store orelse return 0;
    return @intCast(s.count());
}

// ── The MCP surface: one registry.tool() line per function ──────────────────

const KvTools = mcp.registry.Registry(&.{
    mcp.registry.tool(kvSet, &.{ "alloc", "key", "value" }, .{
        .name = "kv_set",
        .title = "Set Key",
        .description = "Store a key-value pair.",
        .annotations = "{\"readOnlyHint\":false,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}",
    }),
    mcp.registry.tool(kvGet, &.{"key"}, .{
        .name = "kv_get",
        .title = "Get Key",
        .description = "Fetch the value for a key, or (not found).",
        .annotations = "{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}",
    }),
    mcp.registry.tool(kvDelete, &.{"key"}, .{
        .name = "kv_delete",
        .title = "Delete Key",
        .description = "Remove a key-value pair.",
        .annotations = "{\"readOnlyHint\":false,\"destructiveHint\":true,\"idempotentHint\":true,\"openWorldHint\":false}",
    }),
    mcp.registry.tool(kvCount, &.{}, .{
        .name = "kv_count",
        .title = "Count Keys",
        .description = "Return how many keys are stored.",
        .annotations = "{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}",
    }),
});

pub fn main(init: std.process.Init) !void {
    mcp.runWithRegistry(init.gpa, init.io, KvTools);
}
