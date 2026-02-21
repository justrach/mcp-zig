#!/bin/bash
# mcp-zig benchmark - measures binary size and startup latency
# Usage: ./benchmark.sh
#
# Requires: zig 0.15+, node (for TypeScript SDK comparison)

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

echo -e "${BOLD}mcp-zig benchmark${RESET}"
echo ""

# -- Build release binary --
echo -e "${DIM}Building release binary...${RESET}"
zig build -Doptimize=ReleaseSmall 2>/dev/null
BINARY="zig-out/bin/mcp-zig"

if [ ! -f "$BINARY" ]; then
  echo "Error: build failed, $BINARY not found"
  exit 1
fi

# Strip if available
if command -v strip &>/dev/null; then
  cp "$BINARY" "${BINARY}.stripped"
  strip "${BINARY}.stripped" 2>/dev/null || true
  # Re-sign on macOS Apple Silicon
  if [[ "$(uname)" == "Darwin" ]] && command -v codesign &>/dev/null; then
    codesign --sign - --force "${BINARY}.stripped" 2>/dev/null || true
  fi
  STRIPPED="${BINARY}.stripped"
else
  STRIPPED="$BINARY"
fi

# -- Binary size --
echo ""
echo -e "${BOLD}=== Binary Size ===${RESET}"
SIZE_BYTES=$(wc -c < "$BINARY" | tr -d ' ')
SIZE_KB=$((SIZE_BYTES / 1024))
STRIPPED_BYTES=$(wc -c < "$STRIPPED" | tr -d ' ')
STRIPPED_KB=$((STRIPPED_BYTES / 1024))

echo -e "  Debug-stripped: ${GREEN}${STRIPPED_KB} KB${RESET} (${STRIPPED_BYTES} bytes)"
echo -e "  Unstripped:     ${SIZE_KB} KB (${SIZE_BYTES} bytes)"
echo ""

# -- Comparison table --
echo -e "${BOLD}=== Size Comparison ===${RESET}"
echo -e "  ${GREEN}mcp-zig${RESET}          ${STRIPPED_KB} KB"
echo -e "  Rust SDK          ~2,000 - 4,000 KB"
echo -e "  Go SDK            ~5,000 - 8,000 KB"
echo -e "  C# NativeAOT      ~8,000 - 15,000 KB"
echo -e "  Python SDK         ~50,000+ KB (+ Python runtime)"
echo -e "  TypeScript SDK     ~52,000+ KB (+ Node.js runtime)"
echo ""
echo -e "  ${YELLOW}mcp-zig is ~$((52000 / STRIPPED_KB))x smaller than TypeScript SDK${RESET}"
echo -e "  ${YELLOW}mcp-zig is ~$((3000 / STRIPPED_KB))x smaller than Rust SDK${RESET}"
echo ""

# -- Startup latency (time to first response) --
echo -e "${BOLD}=== Startup Latency ===${RESET}"
echo -e "${DIM}Measuring time from spawn to initialize response...${RESET}"

# Warm the binary in cache
"$STRIPPED" </dev/null >/dev/null 2>&1 || true

INIT_REQUEST='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bench","version":"1.0.0"}}}'

# Run 10 iterations and average
TOTAL_MS=0
RUNS=10
for i in $(seq 1 $RUNS); do
  START=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  echo "$INIT_REQUEST" | "$STRIPPED" 2>/dev/null | head -1 >/dev/null
  END=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  ELAPSED_US=$(( END - START ))
  TOTAL_MS=$(( TOTAL_MS + ELAPSED_US ))
done
AVG_US=$(( TOTAL_MS / RUNS ))
AVG_MS=$(python3 -c "print(f'{$AVG_US / 1000:.2f}')")

echo -e "  Time to initialize response: ${GREEN}${AVG_MS} ms${RESET} (avg of ${RUNS} runs)"
echo ""

# -- Tools/list latency --
echo -e "${DIM}Measuring initialize + tools/list round-trip...${RESET}"

TOOLS_REQUEST='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

TOTAL_MS=0
for i in $(seq 1 $RUNS); do
  START=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  printf '%s\n%s\n' "$INIT_REQUEST" "$TOOLS_REQUEST" | "$STRIPPED" 2>/dev/null | tail -1 >/dev/null
  END=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  ELAPSED_US=$(( END - START ))
  TOTAL_MS=$(( TOTAL_MS + ELAPSED_US ))
done
AVG_US=$(( TOTAL_MS / RUNS ))
AVG_MS=$(python3 -c "print(f'{$AVG_US / 1000:.2f}')")

echo -e "  Initialize + tools/list: ${GREEN}${AVG_MS} ms${RESET} (avg of ${RUNS} runs)"
echo ""

# -- tools/call latency --
echo -e "${DIM}Measuring initialize + tools/call (read_file) round-trip...${RESET}"

CALL_REQUEST='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}'

TOTAL_MS=0
for i in $(seq 1 $RUNS); do
  START=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  printf '%s\n%s\n' "$INIT_REQUEST" "$CALL_REQUEST" | "$STRIPPED" 2>/dev/null | tail -1 >/dev/null
  END=$(python3 -c 'import time; print(int(time.time() * 1000000))')
  ELAPSED_US=$(( END - START ))
  TOTAL_MS=$(( TOTAL_MS + ELAPSED_US ))
done
AVG_US=$(( TOTAL_MS / RUNS ))
AVG_MS=$(python3 -c "print(f'{$AVG_US / 1000:.2f}')")

echo -e "  Initialize + read_file: ${GREEN}${AVG_MS} ms${RESET} (avg of ${RUNS} runs)"
echo ""

# -- Lines of code --
echo -e "${BOLD}=== Lines of Code ===${RESET}"
TOTAL=0
for f in src/*.zig build.zig; do
  LINES=$(wc -l < "$f" | tr -d ' ')
  TOTAL=$((TOTAL + LINES))
  printf "  %-22s %4d lines\n" "$(basename $f)" "$LINES"
done
echo -e "  ${BOLD}Total${RESET}                  ${GREEN}${TOTAL} lines${RESET}"
echo ""

# Cleanup
rm -f "${BINARY}.stripped"

echo -e "${BOLD}Done.${RESET}"
