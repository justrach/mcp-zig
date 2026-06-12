# MCP v2 / newer-spec update TODO for mcp-zig

This checklist captures what changed upstream after the current `mcp-zig` baseline and what we likely need to do to upgrade cleanly.

## Current baseline in this repo

- `mcp-zig` currently advertises MCP protocol `2025-06-18` in `src/mcp.zig` and README.
- Stdio server supports: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`, `logging/setLevel`, roots discovery via server-initiated `roots/list`, roots changed notifications, cancellation, progress/log notifications, and text tool results with opportunistic `structuredContent` when output is a JSON object.
- HTTP transport is a first Streamable HTTP phase: `POST /mcp`, `Mcp-Session-Id`, `Mcp-Protocol-Version`, `GET /mcp` placeholder SSE response, `DELETE`, `OPTIONS`. It is not yet a full resumable SSE/event-store implementation.
- Registry API currently centers on tool JSON fragments and `dispatchFast(...)`; it does not expose first-class resources, prompts, completions, sampling, elicitation, task/durable execution, icon metadata, `outputSchema`, or protocol-version negotiation.

## Upstream changes to track

### Released after our baseline: `2025-11-25`

Sources: official MCP `2025-11-25` changelog/schema and DeepWiki index for `modelcontextprotocol/modelcontextprotocol`.

- Protocol version is now `2025-11-25`.
- Tool/resource/prompt metadata can include `icons`.
- `Implementation` metadata can include `description` and `websiteUrl`; it still supports `name`, `title`, `version`.
- Tool definitions include:
  - `title` via `BaseMetadata`.
  - `icons`.
  - `annotations` including `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`.
  - `outputSchema` for `structuredContent`.
  - `execution.taskSupport` for task-augmented execution.
- Tool result guidance is clearer: tool execution/validation failures should generally be `CallToolResult { isError: true }`, not protocol-level JSON-RPC errors, so models can self-correct.
- Experimental tasks were added: `tasks/get`, `tasks/result`, `tasks/cancel`, `tasks/list`, task status notifications, task-augmented requests.
- Elicitation expanded/changed, including URL mode elicitation and standards-based enum schema changes.
- Sampling gained tool-calling support through `tools` and `toolChoice`.
- Authorization/security evolved: OIDC discovery, OAuth protected resource metadata, incremental consent via `WWW-Authenticate`, OAuth Client ID Metadata Documents, resource indicators, updated security guidance.
- HTTP transport clarifications:
  - negotiated protocol version header is required on later HTTP requests;
  - invalid `Origin` should get HTTP `403 Forbidden`;
  - polling SSE streams are allowed;
  - stderr is acceptable for stdio logging.
- JSON Schema 2020-12 is the default dialect for MCP schema definitions.

### Draft / likely “v2” direction: currently `2026-07-28` draft

This is much more breaking than `2025-11-25` and should be treated as a separate compatibility layer, not just a constant bump.

- Stateless MCP: removes `initialize` / `notifications/initialized` handshake.
- Every request carries required `_meta` keys:
  - `io.modelcontextprotocol/protocolVersion`
  - `io.modelcontextprotocol/clientInfo`
  - `io.modelcontextprotocol/clientCapabilities`
- New required `server/discover` RPC advertises supported protocol versions, capabilities, and identity.
- Removes protocol-level HTTP sessions and `Mcp-Session-Id`; state should be explicit via server-minted handles in ordinary arguments.
- Replaces HTTP `GET /mcp` listener and resource subscribe/unsubscribe with `subscriptions/listen` as a long-lived POST response stream.
- Removes `ping`, `logging/setLevel`, and `notifications/roots/list_changed`.
- Logging opt-in moves to per-request `_meta` log level; no opt-in means no `notifications/message` for that request.
- Server-initiated requests such as `roots/list`, `sampling/createMessage`, and `elicitation/create` are replaced by the MRTR pattern: results can return `inputRequests`; clients provide `inputResponses` on the next request.
- Tasks move out of core into an official extension.
- Capabilities gain `extensions`.
- Cacheable list/read results require `ttlMs` and `cacheScope` in draft.
- HTTP POST requests add standard MCP request headers such as `Mcp-Method` and `Mcp-Name`.

## Lessons from `justrach/codedb` MCP implementation

`codedb` is currently a useful downstream real-world MCP server built on top of `mcp-zig` utilities.

- It imports `mcp-zig` as `@import("mcp")` and reuses `mcp.json` plus `mcp.mcp.Root`.
- It maintains explicit supported protocol versions: `2025-06-18`, `2025-03-26`, `2024-11-05`.
- It negotiates by echoing the client-requested version when recognized; if the client asks for a future date, it returns the newest supported version. This avoids older clients rejecting a response with a newer `protocolVersion`.
- It uses roots discovery as project-root selection, but falls back to cwd/per-call `project` arguments with safety policy checks.
- It treats tool lists as a runtime artifact, not just a static string: it can filter/gate tools and work around client schema incompatibilities.
- It wraps tool responses with multiple content blocks and `annotations.audience` (`user` summary, `assistant` raw data, optional user guidance).
- It distinguishes context/navigation tools from editing and pushes that guidance into tool descriptions and responses.
- It adds telemetry, caches, deferred indexing, scan-progress hints, and per-call project switching around the MCP protocol layer without changing the protocol core.

## Upgrade TODO

### Phase 0 — Decide compatibility target

- [ ] Decide whether “v2” means released `2025-11-25`, draft `2026-07-28`, or both.
- [ ] Keep `2025-06-18` support while adding new support; do not break existing Claude/Cursor/Codex clients.
- [ ] Add a `SUPPORTED_PROTOCOL_VERSIONS` list and negotiation helper, following the codedb pattern.
- [ ] Add conformance tests for negotiation with `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`, unknown old versions, and unknown future versions.

### Phase 1 — `2025-11-25` low-risk server updates

- [ ] Bump/extend protocol constants to know about `2025-11-25`.
- [ ] Update `initialize` result to include richer `serverInfo`: `title`, `description`, optional `websiteUrl`, optional `icons`.
- [ ] Extend registry `ToolDef` to support optional `title`, `icons`, `annotations`, `outputSchema`, and `execution.taskSupport` without forcing users to hand-write JSON fragments.
- [ ] Keep raw JSON schema fragments as an escape hatch for zero-overhead/minimal binary users.
- [ ] Add tool annotations for bundled/example tools:
  - `read_file`: `readOnlyHint=true`, `destructiveHint=false`, `idempotentHint=true`, `openWorldHint=false`.
  - `list_dir`: same read-only hints.
  - `batch`: read-only iff nested built-ins remain read-only.
- [ ] Add optional `outputSchema` support and advertise it when a handler can produce structured JSON.
- [ ] Improve `tools/call` error mapping: missing params/unknown tool remain protocol errors; bad user arguments or handler failures should return `CallToolResult` with `isError:true`.
- [ ] Preserve opportunistic `structuredContent`, but validate it against `outputSchema` when one exists.
- [ ] Add tests for `isError:true`, `structuredContent`, `outputSchema`, annotations, and icons in `tools/list`.

### Phase 2 — HTTP transport conformance for `2025-11-25`

- [ ] Validate `Mcp-Protocol-Version` on every post-initialize HTTP request and ensure it matches the negotiated session version.
- [ ] Store negotiated protocol version per HTTP session, not just a global constant header.
- [ ] Reject invalid/missing version headers where required.
- [ ] Implement proper `Origin` validation; return `403 Forbidden` for invalid origins.
- [ ] Replace the placeholder GET SSE response with real Streamable HTTP SSE support or clearly gate it as unsupported.
- [ ] Add resumability primitives: event IDs, `Last-Event-ID`, replay/event store, and server-controlled polling disconnection.
- [ ] Add tests for POST JSON response, POST SSE response, GET SSE, DELETE session cleanup, invalid origin, missing/incorrect version header, and CORS headers.

### Phase 3 — Optional feature families

- [ ] Resources: add first-class registry types and handlers for `resources/list`, `resources/read`, templates, and resource links in tool results.
- [ ] Prompts: add `prompts/list` and `prompts/get` support.
- [ ] Completions: add `completions/complete` for tool/resource/prompt argument autocomplete.
- [ ] Elicitation: add types and client-capability negotiation; implement server request helper for `elicitation/create`; include URL-mode support if targeting `2025-11-25` fully.
- [ ] Sampling: add `sampling/createMessage` helper and support the new tool-use fields (`tools`, `toolChoice`) in client-facing types.
- [ ] Tasks: decide whether to implement experimental `2025-11-25` core tasks or wait for the draft extension shape.
- [ ] Authorization: document that current local stdio server has no auth; for remote HTTP, design OAuth protected-resource metadata/OIDC discovery before exposing beyond localhost.

### Phase 4 — Draft / v2 compatibility layer

- [ ] Add a separate stateless request path rather than mutating the existing session-oriented path in place.
- [ ] Implement `server/discover`.
- [ ] Parse required per-request `_meta` protocol version, client info, and capabilities.
- [ ] Return an unsupported-protocol-version error for unsupported versions.
- [ ] Remove dependency on `initialize`/`initialized` for draft-mode requests.
- [ ] Replace server-initiated `roots/list` with MRTR `inputRequests` / `inputResponses` flow, or require roots/project as explicit ordinary tool arguments for draft mode.
- [ ] Remove `Mcp-Session-Id` for draft HTTP mode.
- [ ] Implement `subscriptions/listen` as long-lived POST stream.
- [ ] Remove `ping`, `logging/setLevel`, and roots-list-changed handling in draft mode.
- [ ] Add request-scoped log-level behavior via `_meta`.
- [ ] Add `ttlMs` and `cacheScope` to cacheable results in draft mode.
- [ ] Add `extensions` capability advertisement and a path for extension registration.
- [ ] Build a dual-mode test harness with golden messages for session-mode (`2025-06-18`/`2025-11-25`) and stateless draft-mode.

### Phase 5 — Make this pleasant for downstream users like codedb

- [ ] Port codedb’s version-negotiation helper into `mcp-zig` so downstream servers do not duplicate it.
- [ ] Provide helper builders for `tools/list` instead of requiring static string concatenation.
- [ ] Provide response builders for multi-content results with annotations and for `isError:true` tool execution errors.
- [ ] Provide optional runtime tool filtering/gating like codedb uses for client-specific schema compatibility.
- [ ] Keep APIs zero-dependency and comptime-friendly; make higher-level builders optional.
- [ ] Add a migration guide: `v0.3.x 2025-06-18` -> `v0.4.x 2025-11-25` -> draft/v2.
- [ ] Update README protocol notes, feature matrix, examples, benchmarks, and badges.

## Suggested first PR sequence

1. Protocol negotiation + tests, no behavior break.
2. Tool metadata builder (`title`, `annotations`, `icons`, `outputSchema`) + update built-in tools.
3. `tools/call` error semantics (`isError:true`) + structured-output tests.
4. HTTP version-header/session validation + origin checks.
5. Real SSE/event-store work.
6. Separate branch/feature flag for draft stateless `server/discover` experiment.
