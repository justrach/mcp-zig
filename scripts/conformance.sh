#!/bin/sh
# conformance.sh — MCP dual-mode conformance smoke matrix for mcp-zig.
# Usage: ./scripts/conformance.sh [path-to-server-binary]
# Exits non-zero on the first failed check. Requires: curl, python3.
set -u
BIN="${1:-./zig-out/bin/mcp-zig}"
PORT=8399
FAIL=0

say() { printf '%s\n' "$*"; }
check() { # name expected actual
    if [ "$2" = "$3" ]; then say "ok   $1"; else say "FAIL $1 — expected [$2] got [$3]"; FAIL=1; fi
}
stdio() { printf '%s\n' "$2" | "$BIN" 2>/dev/null; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

MODERN='{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}'

say "── stdio, legacy mode ──"
R=$(stdio x '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}')
check "legacy initialize version" "2025-06-18" "$(printf '%s' "$R" | jget "d['result']['protocolVersion']")"
check "legacy init has no _meta" "False" "$(printf '%s' "$R" | jget "'_meta' in d['result']")"
R=$(stdio x '{"jsonrpc":"2.0","id":2,"method":"ping"}')
check "legacy ping" "{}" "$(printf '%s' "$R" | jget "d['result']")"

say "── stdio, modern (2026-07-28) ──"
R=$(stdio x "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\",\"params\":$MODERN}")
check "modern ping -> -32601" "-32601" "$(printf '%s' "$R" | jget "d['error']['code']")"
R=$(stdio x '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}')
check "modern initialize -> -32601" "-32601" "$(printf '%s' "$R" | jget "d['error']['code']")"
R=$(stdio x "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\",\"params\":$MODERN}")
check "modern tools/list resultType" "complete" "$(printf '%s' "$R" | jget "d['result'].get('resultType')")"
check "modern tools/list ttlMs" "300000" "$(printf '%s' "$R" | jget "d['result'].get('ttlMs')")"
check "modern tools/list meta" "True" "$(printf '%s' "$R" | jget "'io.modelcontextprotocol/serverInfo' in d['result'].get('_meta',{})")"
R=$(stdio x "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"server/discover\",\"params\":$MODERN}")
check "discover versions" "2026-07-28" "$(printf '%s' "$R" | jget "d['result']['supportedVersions'][0]")"
check "discover extensions" "{}" "$(printf '%s' "$R" | jget "d['result']['capabilities'].get('extensions')")"
R=$(stdio x '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}')
check "unknown version -> -32022" "-32022" "$(printf '%s' "$R" | jget "d['error']['code']")"
R=$(stdio x '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"_meta":{"progressToken":"t1"},"name":"read_file","arguments":{"path":"/nonexistent-xyz"}}}')
check "progress notification emitted" "notifications/progress" "$(printf '%s' "$R" | tail -1 | jget "d['method']")"
R=$(stdio x '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"/nonexistent-xyz"}}}')
check "isError true on failure" "True" "$(printf '%s' "$R" | jget "d['result']['isError']")"
R=$(stdio x '{"jsonrpc":"2.0","id":10,"method":"resources/list"}')
check "undeclared resources -> -32601" "-32601" "$(printf '%s' "$R" | jget "d['error']['code']")"

say "── HTTP ──"
"$BIN" --http 127.0.0.1:$PORT & SP=$!
sleep 0.7
trap 'kill $SP 2>/dev/null' EXIT
M='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}'
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
# bodies built in vars: literal {a,b} in double quotes triggers brace expansion
B1="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{$M}}"
B2="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{$M}}"
B3="{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\",\"params\":{$M}}"
B4="{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{$M}}"

check "modern POST no session" "200" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/list' -d "$B1")"
check "missing Mcp-Method -> 400" "400" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -d "$B2")"
check "unknown modern method -> 404" "404" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: ping' -d "$B3")"
check "evil origin -> 403" "403" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H 'Origin: https://evil.example' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/list' -d "$B4")"

SID=$(curl -s -m 5 -i -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')
check "legacy session tools/list" "200" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H "Mcp-Session-Id: $SID" -H 'Mcp-Protocol-Version: 2025-06-18' -d '{"jsonrpc":"2.0","id":6,"method":"tools/list"}')"
check "missing version header -> 400" "400" "$(code -X POST http://127.0.0.1:$PORT/mcp -H 'Content-Type: application/json' -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","id":7,"method":"tools/list"}')"
check "legacy SSE GET opens" "200" "$(code -m 3 http://127.0.0.1:$PORT/mcp -H "Mcp-Session-Id: $SID" -H 'Mcp-Protocol-Version: 2025-06-18')"

kill $SP 2>/dev/null; trap - EXIT
say ""
if [ $FAIL -eq 0 ]; then say "ALL CHECKS PASSED"; else say "FAILURES PRESENT"; exit 1; fi
