# Contributing to mcp-zig

Thanks for your interest in contributing! mcp-zig is intentionally minimal, so contributions should keep that spirit.

## Getting Started

### Prerequisites

- [Zig 0.15](https://ziglang.org/download/)

### Build

```bash
# Debug build (fast compile)
zig build

# Release build (small binary)
zig build -Doptimize=ReleaseSmall

# Strip for smallest size
strip zig-out/bin/mcp-zig
```

### Test

```bash
# Run the server manually (reads from stdin)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}' | ./zig-out/bin/mcp-zig

# Run the client example
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig

# Run benchmarks
./benchmark.sh
```

## What to Contribute

**Good contributions:**
- Bug fixes in the protocol implementation
- Performance improvements
- Better error messages
- New example tools (in `tools.zig`)
- Documentation improvements
- CI/CD improvements

**Not a good fit:**
- Adding external dependencies (the zero-dependency constraint is a core design goal)
- Async/event loop abstractions (MCP stdio is synchronous by design)
- Large framework-style additions (this is a template, not a framework)

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Ensure `zig build` succeeds with no errors
5. Test with Claude Code (register the binary, try your tools)
6. Submit a pull request

## Code Style

- Follow standard Zig conventions
- Keep functions short and focused
- Use comptime where it eliminates runtime overhead
- Write to `out` for tool responses, never use `std.debug.print` in handlers (it goes to stderr, which Claude Code ignores)
- Errors go to `out` as text, never panic

## Protocol Rules

- Every write to stdout must be exactly one JSON object followed by `\n`
- Strip `\n` and `\r` from all tool output before writing
- Notifications (no `id` field) get no response
- The `id` field can be string or integer, handle both

## Questions?

Open an issue or reach out on GitHub.
