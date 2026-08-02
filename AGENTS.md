# AGENTS.md — guide for AI agents working on mcp-zig

A zero-dependency Zig library for building MCP (Model Context Protocol) servers and clients. Dual-mode: legacy MCP (`2025-11-25`/`2025-06-18`/`2025-03-26`/`2024-11-05`, initialize handshake) and modern MCP (`2026-07-28`, stateless, `_meta`-versioned requests).

## Hard requirements

- **Zig `0.17.0-dev` only** (`build.zig.zon` enforces `minimum_zig_version`). Older zigs (including 0.16 stable) WILL fail.
- If `zig` on PATH is not 0.17, find the right binary before building anything.
- **Do not break legacy byte-identity.** Responses to requests WITHOUT `_meta.io.modelcontextprotocol/protocolVersion` must stay byte-identical to pre-modern behavior. Downstream (codedb and others) depend on it. All modern behavior is additive and gated on that `_meta` key.
- **No new dependencies.** Pure std, always.

## Commands

```sh
zig build                        # server (mcp-zig) + client example
zig build package-example        # package-provider example
zig build cookbook               # kv-store cookbook example
zig test src/mcp.zig             # per-suite tests (run the ones you touch):
zig test src/registry.zig src/auth.zig  #   mcp registry auth json http client oauth
./scripts/conformance.sh         # 23-check dual-mode live matrix (needs curl+python3)
```

## Architecture map

| file | role |
|---|---|
| `src/mcp.zig` | stdio server loop, Session, dispatch, protocol versions/negotiation, discover, notifications. The spec core. |
| `src/http.zig` | Streamable HTTP transport: legacy session store + stateless modern path, SSE (`subscriptions/listen`, legacy GET), auth gate, Origin validation. |
| `src/registry.zig` | comptime tool registries: `Registry(defs)`, `ToolDef`, `wrapFn` (fn→handler), `inputSchemaFor`/`tool` (comptime schema gen), `fromPackage(s)` composition. |
| `src/json.zig` | allocation-free JSON-RPC scanner (`scanJsonRpc`, `scanStr/Obj/Int/Bool/Value`), `_meta` capture. Flat, single-pass, no tree. |
| `src/client.zig` | stdio client (`McpClient`, legacy+modern) and `HttpClient` (TLS, SSE, probe, select-timeout, era classification). |
| `src/auth.zig` | server-side bearer auth: HS256 JWT + validator callback, RFC 9728 metadata. |
| `src/oauth.zig` | OAuth 2.1 client: discovery, PKCE, registration, grants, token store, interactive login. |
| `src/tools.zig` | built-in template tools (read_file/list_dir/batch) — the example registry. |
| `src/lib.zig` | package root — re-exports the public API. |

## Conventions (follow them or expect rejection)

- **Scanner-based JSON.** Hot paths never build `std.json` trees. Extract fields with the `scan*` helpers. Note: they are single-level — descend with `scanObj` before reading nested keys (see `classifyProbe` for the pattern).
- **Raw JSON string building** with `std.ArrayList(u8)`; registry payloads are comptime string fragments.
- **Comptime registries.** Optional features are duck-typed `@hasDecl` hooks (`resources_list`, `readResourceFast`, `getPromptFast`, `completeFast`, `dispatchFastOk`, `dispatchFastRaw`, `discover_result`, `initialize_result`) — additive only, never change existing hook signatures.
- **Modern gating.** Stdio: `Session.stamp_meta` per request. HTTP: `handleModernPost`. Removed-in-2026-07-28 methods (`initialize`, `ping`, `logging/setLevel`, roots notifications) must `-32601` for modern callers while staying live for legacy.
- **Error codes**: `-32601` method-not-found (HTTP 404 in modern mode), `-32602` invalid params, `-32020` HeaderMismatch, `-32021` missing capability, `-32022` UnsupportedProtocolVersion (HTTP 400 for the last two).
- **Verify edits landed.** Re-grep edited regions before building; if the build error mentions a line that "should" be fixed, your edit didn't apply.

## zig 0.17 gotchas (all hit in production here)

- `std.Type.Fn.params` → `param_types`; enum `.fields` → use `std.meta.tags`.
- `std.meta.fields` deleted → `std.meta.stringToEnum` / `fieldNames`.
- No `std.Thread.sleep`, no `std.time.timestamp`, no `std.crypto.random` — use `std.Io.sleep`, `std.Io.Clock.now(.real, io)`, `io.random(Secure)`.
- `std.Io.VTable` is an async operation union — use `Stream.read`/`writer()`, never vtable calls directly.
- `ArrayList` is unmanaged: `list.print(alloc, ...)`, `put(alloc, ...)`, no `.writer()`.
- `b.args` in build.zig is gone — the build runner appends `--` args itself.

## Adding a tool (the 10-line version)

```zig
fn myTool(key: []const u8, verbose: bool) []const u8 { ... }
const Tools = mcp.registry.Registry(&.{
    mcp.registry.tool(myTool, &.{"key", "verbose"}, .{ .name = "my_tool", .description = "..." }),
});
```

`inputSchema` is generated from the signature. See `examples/kv-store` for a full product.

## Testing rules

- Every new behavior gets a unit test in its file AND, if it touches the wire, a check in `scripts/conformance.sh`.
- Legacy-mode test must assert byte-level absence of modern keys (`_meta`, `resultType`) — not just presence of the old ones.
- Never commit with a failing suite; run all seven `zig test` invocations plus conformance.
