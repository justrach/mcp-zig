<p align="center">
  <img src="assets/mcp-zig.png" alt="mcp-zig" width="600" />
</p>

# mcp-zig

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Build](https://github.com/justrach/mcp-zig/actions/workflows/build.yml/badge.svg)](https://github.com/justrach/mcp-zig/actions)
[![Zig](https://img.shields.io/badge/Zig-0.16-f7a41d.svg)](https://ziglang.org)
[![MCP](https://img.shields.io/badge/MCP-2025--06--18-green.svg)](https://spec.modelcontextprotocol.io)

**Build MCP servers that fit in a tweet-sized binary.**

131 KB. Zero dependencies. Zero runtime. One static binary that gives Claude Code (or any MCP client) new capabilities.

```
zig build -Doptimize=ReleaseSmall && strip zig-out/bin/mcp-zig
# → 131 KB — 397x smaller than the TypeScript SDK
```

> **Your tools are written in Zig.** This is a Zig template — you write tool handlers as Zig functions. If you want to use Python or TypeScript, use the official SDKs. If you want a 131 KB binary with zero dependencies that starts in milliseconds, keep reading.

---

## Why this exists

Every MCP server I spun up for Claude Code came with 52 MB of `node_modules`. For a process that reads stdin and writes stdout. MCP over stdio is one JSON object per line — it doesn't need an async runtime, a schema validator, or a dependency injection framework.

So I built the thinnest possible implementation. The entire server is ~864 lines of Zig across 8 files. It compiles to a static binary you can drop in a dotfiles repo and forget about.

### How the SDKs compare

| SDK | Language | Distributable | Dependencies |
|-----|----------|---------------|-------------|
| [typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk) | TypeScript | **~52 MB** node_modules + Node.js | 17 npm packages + zod |
| [python-sdk](https://github.com/modelcontextprotocol/python-sdk) | Python | **~50+ MB** site-packages + Python | pydantic, httpx, anyio, starlette... |
| [csharp-sdk](https://github.com/modelcontextprotocol/csharp-sdk) | C# NativeAOT | **~8-15 MB** binary | System.Text.Json + reflection |
| [go-sdk](https://github.com/modelcontextprotocol/go-sdk) | Go | **~5-8 MB** binary | GC + reflect + encoding/json |
| [rust-sdk](https://github.com/modelcontextprotocol/rust-sdk) | Rust | **~2-4 MB** binary | tokio + serde_json + async runtime |
| **mcp-zig** | **Zig** | **131 KB** binary | **0** — just the Zig stdlib compiled in |

### What you ship

| SDK | Deployment |
|-----|-----------|
| TypeScript | `node_modules/` + your code + Node.js installation |
| Python | Virtual environment + your code + Python installation |
| C# / Go / Rust | Single binary (language toolchain to build) |
| **Zig** | **Single 131 KB binary** (Zig to build, nothing to run) |

---

## Important: tools are Zig

**mcp-zig is a Zig-native template.** Your tool handlers are Zig functions that write results to an `ArrayList(u8)`. You can't drop in a Python script or a TypeScript module.

**But you have escape hatches:**
- **C ABI interop** — Zig calls C natively. You can link against C libraries, Rust (`extern "C"`), or Go (cgo)
- **Shell out** — your handler can spawn any external process (`std.process.Child`) and pipe the output back as the tool response
- **MCP-to-MCP** — the included client library (`client.zig`) can call MCP servers written in *any* language over stdio, so you can build cross-language pipelines

If you're already in a Node.js or Python environment and just want tools fast, use the official SDKs. mcp-zig is for when you care about binary size, startup latency, zero dependencies, and distributable simplicity.

---

## Quick start

```bash
git clone https://github.com/justrach/mcp-zig.git
cd mcp-zig
zig build -Doptimize=ReleaseSmall
strip zig-out/bin/mcp-zig    # optional, shrinks further
```

Register with Claude Code in `~/.claude.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/absolute/path/to/mcp-zig",
      "args": []
    }
  }
}
```

Restart Claude Code. Your tools appear as `mcp__my-server__read_file`, `mcp__my-server__list_dir`, etc.

Run the same server over HTTP for remote MCP clients:

```bash
zig-out/bin/mcp-zig --http 127.0.0.1:8000
```

The HTTP transport serves MCP JSON-RPC on `POST /mcp`. `initialize` returns an
`Mcp-Session-Id` header; send that header on later `tools/list` and
`tools/call` requests.

Requires [Zig 0.17.0-dev](https://ziglang.org/download/) (master builds; `minimum_zig_version` in `build.zig.zon` enforces it — 0.16 and earlier are rejected). Verified against `0.17.0-dev.1525+91c6d8a09`.

---

## Use as a Zig package

Instead of cloning, you can import mcp-zig as a dependency in your own Zig project.

**1. Add to your `build.zig.zon`:**
```zig
.dependencies = .{
    .mcp_zig = .{
        .url = "https://github.com/justrach/mcp-zig/archive/main.tar.gz",
        .hash = "...",  // zig build will tell you the correct hash
    },
},
```

**2. Wire it in your `build.zig`:**
```zig
const mcp_dep = b.dependency("mcp_zig", .{});
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

**3. Import in your code:**
```zig
const std = @import("std");
const mcp = @import("mcp");

const my_tools = mcp.registry.Registry(&.{
    .{ .name = "my_tool", .handler = myHandler, .schema = my_schema },
});

pub fn main(init: std.process.Init) !void {
    mcp.runWithRegistry(init.arena.allocator(), init.io, my_tools);
    // Or HTTP: try mcp.http.serveWithRegistry(init.io, init.gpa, .{ .port = 8000 }, my_tools);
}

// Client, JSON helpers, and the built-in template tools are also exported:
const McpClient = mcp.client.McpClient;
const value = mcp.json.getStr(args, "key");
```

Registries can additionally opt into 2026-07-28 features by declaring any of:
`resources_list` / `prompts_list` fragments with `readResourceFast` / `getPromptFast` / `completeFast` hooks (capabilities are then advertised automatically), `dispatchFastRaw` for MRTR (`inputRequired` results), `dispatchFastOk` for accurate `isError`, and `discover_result` / `initialize_result` overrides. The client speaks modern MCP too: `client.useModern(.{ .name = "my-client", .version = "1.0" })` skips `initialize` entirely.

---

## Structure

```
src/
  main.zig           — entry point (5 lines of logic)
  lib.zig            — package root (re-exports public API)
  mcp.zig            — MCP protocol loop + session state (roots, capabilities)
  http.zig           — Streamable HTTP transport entry point (/mcp)
  tools.zig          — YOUR TOOLS GO HERE (read_file + list_dir as examples)
  json.zig           — line reader, field extraction, JSON escaping
  registry.zig       — comptime tool registry (optional, reduces boilerplate)
  client.zig         — MCP client library (spawn server, call tools)
  client_example.zig — client CLI example
examples/
  package-provider/  — package.mcp() provider + server app example
build.zig
build.zig.zon        — package manifest (v0.3.0)
```

**To add your own tools**, edit `tools.zig` when using this repo as a template. Downstream packages can keep their own tool module and pass it to `mcp.runWithRegistry()` or `mcp.http.serveWithRegistry()` without copying source files.

---

## Adding a tool — 4 steps

**1. Add to the enum:**
```zig
pub const Tool = enum {
    read_file,
    list_dir,
    my_new_tool,  // add here
};
```

**2. Add the JSON schema** (this is what Claude reads to understand your tool):
```zig
pub const tools_list =
    \\{"tools":[
    \\...,
    \\{"name":"my_new_tool","description":"Does something useful.","inputSchema":{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}}
    \\]}
;
```

**3. Add a dispatch branch:**
```zig
pub fn dispatch(...) void {
    switch (tool) {
        .read_file    => handleReadFile(alloc, args, out),
        .list_dir     => handleListDir(alloc, args, out),
        .my_new_tool  => handleMyNewTool(alloc, args, out),
    }
}
```

**4. Write the handler:**
```zig
fn handleMyNewTool(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const input = json.getStr(args, "input") orelse {
        out.appendSlice(alloc, "error: missing 'input'") catch {};
        return;
    };
    out.appendSlice(alloc, input) catch {};
}
```

Whatever you write to `out` becomes the tool response shown to Claude. Errors go to `out` too — never panic.

---

## Comptime registry — 1 step (optional)

`registry.zig` reduces the 4-step process to a single definition. It generates `parse()`, `dispatch()`, `dispatchFast()`, and `tools_list` at compile time, matching the injectable server registry interface.

```zig
const registry = @import("registry.zig");

const my_tools = registry.Registry(&.{
    .{ .name = "read_file",  .handler = handleReadFile,  .schema = read_file_schema },
    .{ .name = "list_dir",   .handler = handleListDir,   .schema = list_dir_schema  },
});

// my_tools.parse("read_file")   → 0
// my_tools.dispatch(alloc, 0, args, out)
// my_tools.dispatchFast(alloc, io, 0, "{}", out)
// my_tools.tools_list           → combined JSON
```

You can also define tools in a more library-like typed style instead of hand-writing the whole Tool JSON object. `schema` remains supported as a raw escape hatch, but new packages can compose metadata fields directly:

```zig
const my_tools = registry.Registry(&.{.{
    .name = "greet",
    .title = "Greet",
    .description = "Return a greeting for a name.",
    .handler = registry.wrapFn(greet, &.{"name"}),
    .input_schema =
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    ,
    .output_schema =
        \\{"type":"object","properties":{"greeting":{"type":"string"}},"required":["greeting"]}
    ,
    .annotations = "{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}",
}});
```

### wrapFn — zero-boilerplate handlers

Write a normal Zig function and `wrapFn` generates the MCP handler at comptime:

```zig
fn greet(name: []const u8) []const u8 {
    return name;
}
const handler = registry.wrapFn(greet, &.{"name"});
```

`wrapFn` inspects the function signature at compile time and generates parameter extraction from JSON args (`[]const u8` → `getStr`, `i64` → `getInt`, `bool` → `getBool`). Error unions are caught and their error names written as error messages.

### Custom server without copying mcp-zig sources

A downstream project can depend on `mcp-zig`, define its own registry, and reuse the stdio or HTTP transports directly:

```zig
const std = @import("std");
const mcp = @import("mcp");

const echo_schema =
    \\{"name":"echo","description":"Echo a message.","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}
;

fn echo(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const message = mcp.json.getStr(args, "message") orelse "";
    out.appendSlice(alloc, message) catch {};
}

const tools = mcp.registry.Registry(&.{
    .{ .name = "echo", .handler = echo, .schema = echo_schema },
});

pub fn main(init: std.process.Init) !void {
    mcp.runWithRegistry(init.arena.allocator(), init.io, tools);
    // Or HTTP: try mcp.http.serveWithRegistry(init.io, init.gpa, .{ .port = 8000 }, tools);
}
```

For fully custom fast paths, provide a registry type with `tools_list`, `parse(name)`, and `dispatchFast(alloc, io, tool, args_raw, out)`. Add `initialize_result` if you want custom `serverInfo` or `instructions` in the MCP `initialize` response.

### Package-level MCP providers

Reusable Zig libraries can expose their own APIs as MCP tools without becoming server apps. The package convention is a public `mcp()` function:

```zig
// inside a library package, e.g. mydb/root.zig
const std = @import("std");
const mcp_zig = @import("mcp");

const query_schema =
    \\{"name":"mydb_query","description":"Run a query.","inputSchema":{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}}
;

fn query(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const sql = mcp_zig.json.getStr(args, "sql") orelse "";
    // Call the library's real API here, then write the MCP result.
    out.appendSlice(alloc, sql) catch {};
}

pub fn mcp() mcp_zig.registry.ToolPack {
    return mcp_zig.registry.pack(&.{
        .{ .name = "mydb_query", .handler = query, .schema = query_schema },
    });
}
```

Then an MCP server app can mount packages directly:

```zig
const std = @import("std");
const mcp = @import("mcp");
const mydb = @import("mydb");
const search = @import("search");

const Registry = mcp.registry.fromPackages(.{ mydb, search });

pub fn main(init: std.process.Init) !void {
    mcp.runWithRegistry(init.arena.allocator(), init.io, Registry);
}
```

`pub const mcp_tools = mcp_zig.registry.pack(...)` is also supported when a library prefers a data export, and apps can compose those explicitly with `mcp.registry.fromPacks(.{ lib.mcp_tools, other.mcp_tools })`.

### Full package example

The repository includes a buildable example at `examples/package-provider` showing the two-package shape:

- `src/tool_package.zig` acts like a reusable library and exposes `pub fn mcp() mcp_zig.registry.ToolPack`.
- `src/package_server.zig` imports that package, mounts it with `mcp.registry.fromPackages(.{example_tools})`, and serves it over stdio or HTTP.
- `build.zig.zon` shows how a consumer project depends on `mcp_zig`; it uses a local `.path = "../.."` in this checkout, while external projects should use the URL/hash dependency form above.

Run it from the repo root:

```bash
zig build package-example
./zig-out/bin/mcp-package-server-example
./zig-out/bin/mcp-package-server-example --http 127.0.0.1:8000
```

Or build it as its own consumer project:

```bash
zig build --build-file examples/package-provider/build.zig
```

---

## Client — calling MCP servers from Zig

mcp-zig includes a client library for calling any MCP server programmatically — regardless of what language that server is written in.

### Library API

```zig
const McpClient = @import("client.zig").McpClient;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var client = try McpClient.init(alloc, io, &.{"/path/to/server"}, null);
    defer client.deinit();

    const init_result = try client.initialize();
    defer alloc.free(init_result);
    try client.notifyInitialized();

    const tools = try client.listTools();
    defer alloc.free(tools);

    const result = try client.callTool("read_file", "{\"path\":\"hello.txt\"}");
    defer alloc.free(result);
}
```

### One-shot convenience

```zig
const callOnce = @import("client.zig").callOnce;

// Spawn → initialize → call → return → clean up, in one call
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const result = try callOnce(alloc, io, &.{"/path/to/server"}, "read_file", "{\"path\":\"hello.txt\"}");
    defer alloc.free(result);
}
```

### CLI example

```bash
zig build
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig                          # list tools
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig read_file '{"path":"."}'  # call a tool
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig batch '{"operations":[{"tool":"read_file","arguments":{"path":"README.md","max_bytes":80}},{"tool":"list_dir","arguments":{"path":"src"}}]}'
```

The `batch` tool returns a structured JSON object with ordered per-item results, so clients can group several filesystem reads into a single `tools/call` without losing partial-failure information.

---

## Build options

```bash
zig build                              # debug (fast compile)
zig build -Doptimize=ReleaseSmall      # release (small binary)
zig build -Dio-backend=evented         # Linux only; macOS/other targets fall back to threaded
strip zig-out/bin/mcp-zig              # shrink further
codesign --sign - --force zig-out/bin/mcp-zig   # macOS Apple Silicon only
```

`mcp-zig` uses `std.Io.Threaded` by default. The `-Dio-backend=evented` option is gated to Linux builds so you can experiment with `std.Io.Evented` there without pulling in the current macOS `Dispatch` backend issues. On macOS and other non-Linux targets, the binaries continue to use `Threaded`.

---

## Protocol notes

**Protocol versions: `2026-07-28` (modern/stateless) + `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (legacy)** ([spec](https://spec.modelcontextprotocol.io)). The server is dual-mode:

- **Modern (`2026-07-28`)**: requests self-describe via `params._meta."io.modelcontextprotocol/protocolVersion"` — no `initialize` handshake (it and `ping`/`logging/setLevel`/`notifications/roots/list_changed` answer `-32601` for modern callers). `server/discover` advertises versions/capabilities; every modern result is stamped with `_meta."io.modelcontextprotocol/serverInfo"`; unknown modern versions get `UnsupportedProtocolVersionError` (`-32020` is `HeaderMismatch`, `-32022` unsupported version). Over HTTP, modern POSTs need no session but must mirror `MCP-Protocol-Version`/`Mcp-Method`(/`Mcp-Name`) headers; unknown methods are `404` + `-32601`; `subscriptions/listen` returns a long-lived SSE stream (keep-alive comment lines, `X-Accel-Buffering: no`).
- **Legacy**: the initialize handshake negotiates conservatively (echo known versions, clamp future to newest legacy `2025-11-25`, oldest for unknown-old), with sessions over HTTP exactly as before.

MRTR note: server-initiated requests (`roots/list` et al.) are legacy-only. Modern clients pass roots/project context as explicit tool arguments. Multi round-trip requests (MRTR) are supported via the optional `dispatchFastRaw` registry hook: it owns the entire result object (so tools can return `resultType:"inputRequired"` with `inputRequests` and a `requestState`), and the follow-up request's `params._meta` — including `inputResponses` — is forwarded to the hook for correlation.

Resources/prompts/completions: registries may add `resources_list` / `prompts_list` JSON fragments plus `readResourceFast`, `getPromptFast`, and `completeFast` hooks; capabilities are then advertised automatically (legacy initialize and modern `server/discover` alike), and the methods serve on stdio and HTTP in both protocol modes with the schema-required fields. The client library also speaks modern MCP: `client.useModern(.{...})` skips initialize and stamps every request with `_meta` (see `McpClient.discover/listTools/callTool`).

MCP over stdio is **newline-delimited JSON-RPC 2.0** — one JSON object per line, no Content-Length headers (unlike LSP). The critical invariant: every write to stdout is exactly one JSON object followed by `\n`.

The `writeResult` function in `mcp.zig` strips `\n` and `\r` from result strings before writing. This matters because Zig `\\` multiline string literals embed literal newlines — without stripping, Claude Code's ReadBuffer would parse each line as a separate (invalid) JSON-RPC message and kill the server.

MCP over HTTP is available with `mcp-zig --http [host:port]`. The first
implementation supports `POST /mcp` request/response JSON-RPC with session
headers, plus `GET /mcp` as an SSE-compatible placeholder event. Resumable
long-lived SSE streams are still future work.

### Rust SDK conformance notes

The Rust SDK centers on a service/handler object that exposes MCP capabilities and is attached to a transport with `.serve(...)`. mcp-zig now follows the same separation of concerns in Zig form:

| Rust SDK concept | mcp-zig equivalent |
|------------------|--------------------|
| service/handler exposing tools | package/module exposing `pub fn mcp() ToolPack` |
| tool router/list/call wiring | `mcp.registry.fromPackages(...)` or `Registry(...)` |
| stdio transport | `mcp.runWithRegistry(...)` |
| Streamable HTTP transport | `mcp.http.serveWithRegistry(...)` |
| client over child-process stdio | `mcp.client.McpClient` |

Current scope: mcp-zig conforms to MCP's JSON-RPC lifecycle for initialization, tools/list, tools/call, ping, stdio, and the initial HTTP request/response flow. It also tracks roots, logging level, cancellation, and progress notifications. It does not yet expose Rust-SDK-style first-class resources, prompts, completions, sampling, elicitation, or resumable Streamable HTTP SSE.

### What's new in v0.3.0

| Feature | Description |
|---------|------------|
| **Package providers** | External Zig libraries can expose `pub fn mcp() ToolPack` and be mounted with `mcp.registry.fromPackages(...)` |
| **Tool packs** | Libraries can export `mcp.registry.pack(...)` data packs and apps can combine them with `fromPacks(...)` |
| **Injectable transports** | Stdio and HTTP servers can run any compatible registry through `runWithRegistry(...)` and `serveWithRegistry(...)` |
| **Buildable package example** | `examples/package-provider` demonstrates the `build.zig.zon` consumer setup |

### What's new in v0.2.0 (2025-06-18 protocol)

| Feature | Description |
|---------|------------|
| **Client capability parsing** | Server reads `params.capabilities` from the `initialize` request |
| **Workspace roots** | After handshake, server sends `roots/list` to discover client workspace directories |
| **Roots change tracking** | Handles `notifications/roots/list_changed` — re-queries roots automatically |
| **Bidirectional JSON-RPC** | New `writeRequest()` for server-to-client requests (not just responses) |
| **Title field** | `serverInfo` includes `title` for human-readable display names |
| **Session state** | `Session` struct tracks capabilities, pending requests, and parsed roots across the connection |

The server now participates in the full MCP lifecycle:

```
Client                          Server
  │                               │
  ├─ initialize ─────────────────►│  ← parses client capabilities
  │◄──────────────── result ──────┤  ← returns 2025-06-18 + tools cap
  │                               │
  ├─ notifications/initialized ──►│
  │◄──────────── roots/list ──────┤  ← if client supports roots
  ├─ result (roots array) ───────►│  ← stores workspace roots
  │                               │
  ├─ tools/list ─────────────────►│
  │◄──────────────── result ──────┤
  │                               │
  ├─ notifications/roots/list_changed ►│
  │◄──────────── roots/list ──────┤  ← re-queries on change
  ├─ result (updated roots) ─────►│
```

---

## Coming soon

- Structured tool output (`outputSchema` / `structuredContent`)
- Elicitation — server requesting user input via client UI
- Resource links — returning `ResourceLink` content blocks from tools
- Completions — autocomplete for tool arguments
- Resumable Streamable HTTP SSE event store
- More example tools (database queries, HTTP requests, file watchers)
- Cross-compilation targets (Linux, Windows from macOS)
- Benchmark suite for latency and throughput profiling

Have ideas? [Open an issue](https://github.com/justrach/mcp-zig/issues).

---

## License

MIT

---

**Blog post:** [mcp-zig: A 131 KB MCP Server Template in Zig](https://justrach.com/blog/building-mcp-servers-in-zig) — deeper dive into the architecture, benchmarks, and how it was built.
