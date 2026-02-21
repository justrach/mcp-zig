# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in mcp-zig, please report it responsibly.

**Do not open a public issue.**

Instead, email [security@rachpradhan.com](mailto:security@rachpradhan.com) with:

- A description of the vulnerability
- Steps to reproduce
- Impact assessment

I'll acknowledge receipt within 48 hours and aim to release a fix within 7 days for critical issues.

## Scope

mcp-zig is a template for building MCP servers. Security considerations include:

- **Tool handlers** — the example `read_file` handler reads arbitrary files. If you ship this in production, restrict file access to safe directories.
- **JSON parsing** — the parser handles untrusted input from stdin. Report any crashes or unexpected behavior with malformed JSON.
- **Child process spawning** — the client library spawns server processes. Ensure server paths are trusted.

## Supported Versions

| Version | Supported |
|---------|-----------|
| main    | Yes       |
