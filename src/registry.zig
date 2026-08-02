// mcp-zig — Comptime tool registry
//
// Reduces tool registration from 4 manual steps to 1:
//   const my_tools = registry.define(.{
//       .{ "read_file",  handleReadFile,  read_file_schema },
//       .{ "list_dir",   handleListDir,   list_dir_schema  },
//   });
//
// Generates parse(), dispatch(), dispatchFast(), and tools_list at comptime.
// Also provides wrapFn() to wrap simple Zig functions as MCP handlers.

const std = @import("std");
const json = @import("json.zig");

/// Handler function signature for MCP tools.
pub const Handler = *const fn (std.mem.Allocator, *const std.json.ObjectMap, *std.ArrayList(u8)) void;

/// Default input schema for tools that take no arguments.
pub const empty_input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

/// A single tool definition.
///
/// Two styles are supported:
///
/// 1. Raw schema fragment (old/minimal style):
///    `.schema = "{\"name\":...,\"inputSchema\":...}"`
///
/// 2. Library-style fields (new/composable style):
///    `.description = "...", .input_schema = "{...}", .annotations = "{...}"`
///
/// The raw fields ending in `_schema`, `annotations`, `icons`, `execution`, and
/// `meta` are JSON fragments. `name`, `title`, and `description` are escaped as
/// JSON strings at comptime.
///
/// 2026-07-28 note: parameter-level `x-mcp-header` extension properties (which
/// make conforming clients mirror argument values into `Mcp-Param-{Name}`
/// request headers) can be declared directly inside `schema`/`input_schema`
/// JSON — both are passed through verbatim. The built-in tools declare none,
/// so no `Mcp-Param-*` header validation is required of this server.
pub const ToolDef = struct {
    name: []const u8,
    handler: Handler,

    /// Complete Tool JSON fragment. If set, this is used verbatim for
    /// backwards compatibility and maximum control.
    schema: ?[]const u8 = null,

    /// Library-style fields used when `schema == null`.
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    input_schema: []const u8 = empty_input_schema,
    output_schema: ?[]const u8 = null,
    annotations: ?[]const u8 = null,
    icons: ?[]const u8 = null,
    execution: ?[]const u8 = null,
    meta: ?[]const u8 = null,
};

fn jsonString(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "\"";
    inline for (s) |c| {
        switch (c) {
            '"' => out = out ++ "\\\"",
            '\\' => out = out ++ "\\\\",
            '\n' => out = out ++ "\\n",
            '\r' => out = out ++ "\\r",
            '\t' => out = out ++ "\\t",
            else => {
                if (c < 0x20) @compileError("ToolDef strings cannot contain unescaped control characters");
                out = out ++ &[_]u8{c};
            },
        }
    }
    return out ++ "\"";
}

/// Return the Tool JSON object for a definition.
/// When `.schema` is supplied it is used verbatim; otherwise this builds the
/// standard MCP Tool object from library-style fields.
pub fn toolJson(comptime def: ToolDef) []const u8 {
    if (def.schema) |raw| return raw;

    comptime {
        const desc = def.description orelse
            @compileError("ToolDef " ++ def.name ++ " must set either .schema or .description");

        var buf: []const u8 = "{\"name\":" ++ jsonString(def.name);
        if (def.title) |title| buf = buf ++ ",\"title\":" ++ jsonString(title);
        buf = buf ++ ",\"description\":" ++ jsonString(desc);
        if (def.icons) |icons| buf = buf ++ ",\"icons\":" ++ icons;
        buf = buf ++ ",\"inputSchema\":" ++ def.input_schema;
        if (def.output_schema) |output_schema| buf = buf ++ ",\"outputSchema\":" ++ output_schema;
        if (def.execution) |execution| buf = buf ++ ",\"execution\":" ++ execution;
        if (def.annotations) |annotations| buf = buf ++ ",\"annotations\":" ++ annotations;
        if (def.meta) |meta| buf = buf ++ ",\"_meta\":" ++ meta;
        buf = buf ++ "}";
        return buf;
    }
}

/// Conventional tool-pack type for library authors.
///
/// A Zig library can expose `pub const mcp_tools = mcp.registry.pack(&.{ ... });`
/// without also owning a server binary. An application can then mount one or
/// more library tool packs with `mcp.registry.fromPacks(.{ lib.mcp_tools, ... })`.
pub const ToolPack = []const ToolDef;

/// Mark a comptime list of tool definitions as a reusable tool pack.
pub fn pack(comptime defs: []const ToolDef) ToolPack {
    return defs;
}

/// Define a tool registry from an array of ToolDefs.
/// Returns a struct with parse(), dispatch(), dispatchFast(), and tools_list.
pub fn Registry(comptime defs: []const ToolDef) type {
    return struct {
        /// Parse a tool name string into an index. Returns null if unknown.
        pub fn parse(name: []const u8) ?usize {
            inline for (defs, 0..) |def, i| {
                if (std.mem.eql(u8, name, def.name)) return i;
            }
            return null;
        }

        /// Dispatch a parsed tool index.
        pub fn dispatch(
            alloc: std.mem.Allocator,
            index: usize,
            args: *const std.json.ObjectMap,
            out: *std.ArrayList(u8),
        ) void {
            inline for (defs, 0..) |def, i| {
                if (index == i) {
                    def.handler(alloc, args, out);
                    return;
                }
            }
        }

        /// Dispatch from raw JSON args, matching the reusable server interface.
        /// This fallback parses args into a JSON object and calls dispatch().
        pub fn dispatchFast(
            alloc: std.mem.Allocator,
            io: std.Io,
            index: usize,
            args_raw: []const u8,
            out: *std.ArrayList(u8),
        ) void {
            _ = io;
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_raw, .{}) catch {
                out.appendSlice(alloc, "error: invalid arguments") catch {};
                return;
            };
            defer parsed.deinit();

            if (parsed.value != .object) {
                out.appendSlice(alloc, "error: arguments must be an object") catch {};
                return;
            }

            dispatch(alloc, index, &parsed.value.object, out);
        }

        /// Combined tools/list JSON response, generated at comptime.
        pub const tools_list = blk: {
            var buf: []const u8 = "{\"tools\":[";
            for (defs, 0..) |def, i| {
                if (i > 0) buf = buf ++ ",";
                buf = buf ++ toolJson(def);
            }
            buf = buf ++ "]}";
            break :blk buf;
        };

        /// Number of registered tools.
        pub const count = defs.len;

        /// Get tool name by index.
        pub fn nameAt(index: usize) []const u8 {
            inline for (defs, 0..) |def, i| {
                if (index == i) return def.name;
            }
            return "unknown";
        }
    };
}

/// Extract MCP tools from a package/module.
///
/// Preferred package convention:
///
/// ```zig
/// pub fn mcp() mcp_zig.registry.ToolPack { return mcp_zig.registry.pack(&.{ ... }); }
/// ```
///
/// `pub const mcp_tools = ...` is also accepted for packages that prefer data
/// exports over function exports.
pub fn packageTools(comptime Package: type) ToolPack {
    if (@hasDecl(Package, "mcp")) {
        const provider = @field(Package, "mcp");
        if (@typeInfo(@TypeOf(provider)) == .@"fn") {
            return provider();
        }
        if (!@hasDecl(Package, "mcp_tools")) {
            @compileError(@typeName(Package) ++ ".mcp must be pub fn mcp() mcp.registry.ToolPack");
        }
    }

    if (@hasDecl(Package, "mcp_tools")) {
        return @field(Package, "mcp_tools");
    }

    @compileError(@typeName(Package) ++ " must expose pub fn mcp() mcp.registry.ToolPack or pub const mcp_tools");
}

/// Build a registry from one package/module exposing `package.mcp()`.
pub fn fromPackage(comptime Package: type) type {
    return fromPacks(.{packageTools(Package)});
}

/// Compose reusable tool packs exported by one or more Zig libraries.
pub fn fromPacks(comptime packs: anytype) type {
    const Packs = @TypeOf(packs);
    const info = @typeInfo(Packs);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("registry.fromPacks expects a tuple, e.g. .{ lib_a.mcp_tools, lib_b.mcp_tools }");
    }

    comptime var total_count: usize = 0;
    inline for (packs) |tool_pack| {
        const defs = tool_pack[0..];
        total_count += defs.len;
    }

    return struct {
        /// Parse a tool name string into a global pack index. Returns null if unknown.
        pub fn parse(name: []const u8) ?usize {
            var base: usize = 0;
            inline for (packs) |tool_pack| {
                const defs = tool_pack[0..];
                inline for (defs, 0..) |def, i| {
                    if (std.mem.eql(u8, name, def.name)) return base + i;
                }
                base += defs.len;
            }
            return null;
        }

        /// Dispatch a parsed global pack index.
        pub fn dispatch(
            alloc: std.mem.Allocator,
            index: usize,
            args: *const std.json.ObjectMap,
            out: *std.ArrayList(u8),
        ) void {
            var base: usize = 0;
            inline for (packs) |tool_pack| {
                const defs = tool_pack[0..];
                if (index < base + defs.len) {
                    inline for (defs, 0..) |def, i| {
                        if (index == base + i) {
                            def.handler(alloc, args, out);
                            return;
                        }
                    }
                }
                base += defs.len;
            }
        }

        /// Dispatch from raw JSON args, matching the reusable server interface.
        pub fn dispatchFast(
            alloc: std.mem.Allocator,
            io: std.Io,
            index: usize,
            args_raw: []const u8,
            out: *std.ArrayList(u8),
        ) void {
            _ = io;
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_raw, .{}) catch {
                out.appendSlice(alloc, "error: invalid arguments") catch {};
                return;
            };
            defer parsed.deinit();

            if (parsed.value != .object) {
                out.appendSlice(alloc, "error: arguments must be an object") catch {};
                return;
            }

            dispatch(alloc, index, &parsed.value.object, out);
        }

        /// Combined tools/list JSON response for all mounted packs.
        pub const tools_list = blk: {
            var buf: []const u8 = "{\"tools\":[";
            var first = true;
            for (packs) |tool_pack| {
                const defs = tool_pack[0..];
                for (defs) |def| {
                    if (!first) buf = buf ++ ",";
                    first = false;
                    buf = buf ++ toolJson(def);
                }
            }
            buf = buf ++ "]}";
            break :blk buf;
        };

        /// Number of mounted tools.
        pub const count = total_count;

        /// Get mounted tool name by global pack index.
        pub fn nameAt(index: usize) []const u8 {
            var base: usize = 0;
            inline for (packs) |tool_pack| {
                const defs = tool_pack[0..];
                if (index < base + defs.len) {
                    inline for (defs, 0..) |def, i| {
                        if (index == base + i) return def.name;
                    }
                }
                base += defs.len;
            }
            return "unknown";
        }
    };
}

/// Compose packages/modules that expose `pub fn mcp() ToolPack`.
pub fn fromPackages(comptime packages: anytype) type {
    const Packages = @TypeOf(packages);
    const info = @typeInfo(Packages);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("registry.fromPackages expects a tuple, e.g. .{ sqlite, my_lib, another_lib }");
    }

    comptime var total_count: usize = 0;
    inline for (packages) |Package| {
        const defs = comptime packageTools(Package);
        total_count += defs.len;
    }

    return struct {
        /// Parse a tool name string into a global package index. Returns null if unknown.
        pub fn parse(name: []const u8) ?usize {
            var base: usize = 0;
            inline for (packages) |Package| {
                const defs = comptime packageTools(Package);
                inline for (defs, 0..) |def, i| {
                    if (std.mem.eql(u8, name, def.name)) return base + i;
                }
                base += defs.len;
            }
            return null;
        }

        /// Dispatch a parsed global package index.
        pub fn dispatch(
            alloc: std.mem.Allocator,
            index: usize,
            args: *const std.json.ObjectMap,
            out: *std.ArrayList(u8),
        ) void {
            var base: usize = 0;
            inline for (packages) |Package| {
                const defs = comptime packageTools(Package);
                if (index < base + defs.len) {
                    inline for (defs, 0..) |def, i| {
                        if (index == base + i) {
                            def.handler(alloc, args, out);
                            return;
                        }
                    }
                }
                base += defs.len;
            }
        }

        /// Dispatch from raw JSON args, matching the reusable server interface.
        pub fn dispatchFast(
            alloc: std.mem.Allocator,
            io: std.Io,
            index: usize,
            args_raw: []const u8,
            out: *std.ArrayList(u8),
        ) void {
            _ = io;
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_raw, .{}) catch {
                out.appendSlice(alloc, "error: invalid arguments") catch {};
                return;
            };
            defer parsed.deinit();

            if (parsed.value != .object) {
                out.appendSlice(alloc, "error: arguments must be an object") catch {};
                return;
            }

            dispatch(alloc, index, &parsed.value.object, out);
        }

        /// Combined tools/list JSON response for all mounted packages.
        pub const tools_list = blk: {
            var buf: []const u8 = "{\"tools\":[";
            var first = true;
            for (packages) |Package| {
                const defs = packageTools(Package);
                for (defs) |def| {
                    if (!first) buf = buf ++ ",";
                    first = false;
                    buf = buf ++ toolJson(def);
                }
            }
            buf = buf ++ "]}";
            break :blk buf;
        };

        /// Number of mounted tools.
        pub const count = total_count;

        /// Get mounted tool name by global package index.
        pub fn nameAt(index: usize) []const u8 {
            var base: usize = 0;
            inline for (packages) |Package| {
                const defs = comptime packageTools(Package);
                if (index < base + defs.len) {
                    inline for (defs, 0..) |def, i| {
                        if (index == base + i) return def.name;
                    }
                }
                base += defs.len;
            }
            return "unknown";
        }
    };
}

// ── wrapFn: wrap simple Zig functions as MCP handlers ────────────────────────
//
// Takes a function with typed parameters and wraps it into the Handler signature.
// Parameter extraction is done via json.getStr/getInt/getBool based on type.
//
// Supported parameter types:
//   []const u8  → json.getStr(args, param_name)
//   i64         → json.getInt(args, param_name)
//   bool        → json.getBool(args, param_name)
//
// The wrapped function can return:
//   []const u8  → written directly to out
//   void        → nothing written
//   ![]const u8 → on error, error message written
//
// Example:
//   fn greet(name: []const u8) []const u8 { return name; }
//   const handler = registry.wrapFn(greet, &.{"name"});

/// Wrap a function with named JSON parameters into an MCP Handler.
/// `param_names` maps positional parameters to JSON field names.
pub fn wrapFn(
    comptime func: anytype,
    comptime param_names: []const []const u8,
) Handler {
    const F = @TypeOf(func);
    const info = @typeInfo(F).@"fn";

    return struct {
        fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
            // Extract parameters at comptime
            var params: std.meta.ArgsTuple(F) = undefined;
            inline for (info.param_types, 0..) |param_type, i| {
                const name_str = param_names[i];
                const T = param_type orelse @compileError("wrapFn: anytype parameters are not supported");

                if (T == []const u8) {
                    params[i] = json.getStr(args, name_str) orelse {
                        out.appendSlice(alloc, "error: missing '") catch {};
                        out.appendSlice(alloc, name_str) catch {};
                        out.appendSlice(alloc, "'") catch {};
                        return;
                    };
                } else if (T == i64) {
                    params[i] = json.getInt(args, name_str) orelse 0;
                } else if (T == bool) {
                    params[i] = json.getBool(args, name_str);
                } else if (T == std.mem.Allocator) {
                    params[i] = alloc;
                } else {
                    @compileError("wrapFn: unsupported parameter type for '" ++ name_str ++ "'");
                }
            }

            // Call the function
            const ReturnType = info.return_type.?;
            if (@typeInfo(ReturnType) == .error_union) {
                if (@call(.auto, func, params)) |result| {
                    writeReturnValue(alloc, out, result);
                } else |err| {
                    out.appendSlice(alloc, "error: ") catch {};
                    out.appendSlice(alloc, @errorName(err)) catch {};
                }
            } else {
                const result = @call(.auto, func, params);
                writeReturnValue(alloc, out, result);
            }
        }

        /// Emit a wrapped function's return value as tool result text.
        /// Strings pass through; integers/bools are formatted; void is silent.
        fn writeReturnValue(alloc: std.mem.Allocator, out: *std.ArrayList(u8), result: anytype) void {
            const R = @TypeOf(result);
            if (R == []const u8 or R == []u8) {
                out.appendSlice(alloc, result) catch {};
            } else if (R == void) {
                // nothing to write
            } else if (R == bool) {
                out.appendSlice(alloc, if (result) "true" else "false") catch {};
            } else if (@typeInfo(R) == .int) {
                var tmp: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{result}) catch return;
                out.appendSlice(alloc, s) catch {};
            } else {
                @compileError("wrapFn: unsupported return type " ++ @typeName(R) ++ " (use []const u8, int, bool, or void)");
            }
        }
    }.handler;
}

// ── Comptime schema generation: write the function, get the tool ─────────────
//
// `wrapFn` already knows every parameter's name and type at comptime, so the
// JSON Schema can be generated instead of hand-written. Type mapping matches
// wrapFn's extraction semantics exactly:
//
//   []const u8  → {"type":"string"}   (required — wrapFn errors when missing)
//   i64         → {"type":"integer"}  (optional — wrapFn defaults to 0)
//   bool        → {"type":"boolean"}  (optional — wrapFn defaults to false)
//   std.mem.Allocator → injected, excluded from the schema
//
// Example:
//   fn greet(name: []const u8, excited: bool) []const u8 { ... }
//   const Tools = registry.Registry(&.{
//       registry.tool(greet, &.{ "name", "excited" }, .{
//           .name = "greet", .description = "Greet someone.",
//       }),
//   });

/// Generate a JSON Schema `inputSchema` object from a function's signature.
/// `param_names` follows the wrapFn convention (one entry per parameter,
/// including a placeholder for any Allocator parameter).
pub fn inputSchemaFor(comptime func: anytype, comptime param_names: []const []const u8) []const u8 {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    comptime {
        var props: []const u8 = "";
        var required: []const u8 = "";
        var n_props: usize = 0;
        var n_req: usize = 0;
        for (info.param_types, 0..) |param_type, i| {
            const T = param_type orelse @compileError("inputSchemaFor: anytype parameters are not supported");
            if (T == std.mem.Allocator) continue;
            const name = param_names[i];
            const ty = switch (T) {
                []const u8 => "string",
                i64 => "integer",
                bool => "boolean",
                else => @compileError("inputSchemaFor: unsupported parameter type for '" ++ name ++ "'"),
            };
            if (n_props != 0) props = props ++ ",";
            props = props ++ "\"" ++ name ++ "\":{\"type\":\"" ++ ty ++ "\"}";
            if (T == []const u8) {
                if (n_req != 0) required = required ++ ",";
                required = required ++ "\"" ++ name ++ "\"";
                n_req += 1;
            }
            n_props += 1;
        }
        return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "]}";
    }
}

pub const FnToolOpts = struct {
    name: []const u8,
    description: []const u8,
    title: ?[]const u8 = null,
    annotations: ?[]const u8 = null,
};

/// One-step product-to-MCP: wrap a function AND generate its inputSchema.
/// The returned ToolDef drops straight into `Registry(&.{...})`.
pub fn tool(comptime func: anytype, comptime param_names: []const []const u8, comptime opts: FnToolOpts) ToolDef {
    return .{
        .name = opts.name,
        .handler = wrapFn(func, param_names),
        .title = opts.title,
        .description = opts.description,
        .input_schema = inputSchemaFor(func, param_names),
        .annotations = opts.annotations,
    };
}

test "inputSchemaFor generates schema from a function signature" {
    const testing = std.testing;
    const f = struct {
        fn f(alloc: std.mem.Allocator, name: []const u8, count: i64, loud: bool) []const u8 {
            _ = alloc;
            _ = count;
            _ = loud;
            return name;
        }
    }.f;
    const schema = comptime inputSchemaFor(f, &.{ "alloc", "name", "count", "loud" });
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"},\"loud\":{\"type\":\"boolean\"}},\"required\":[\"name\"]}",
        schema,
    );
    // no params at all → empty object schema
    const g = struct {
        fn g() void {}
    }.g;
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
        comptime inputSchemaFor(g, &.{}),
    );
}

test "registry.tool wraps fn and generated schema into tools_list" {
    const testing = std.testing;
    const kv_get = struct {
        fn kv_get(key: []const u8) []const u8 {
            return key;
        }
    }.kv_get;
    const Tools = Registry(&.{
        tool(kv_get, &.{"key"}, .{
            .name = "kv_get",
            .title = "KV Get",
            .description = "Fetch a value by key.",
        }),
    });
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"name\":\"kv_get\"") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}},\"required\":[\"key\"]}") != null);
    // and the wrapped handler actually dispatches
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(testing.allocator);
    try args.put(testing.allocator, "key", .{ .string = "hello" });
    const t = Tools.parse("kv_get") orelse return error.TestUnexpectedResult;
    Tools.dispatch(testing.allocator, t, &args, &out);
    try testing.expectEqualStrings("hello", out.items);
}

test "Registry builds tools/list from library-style ToolDef fields" {
    const testing = std.testing;

    const typed_input_schema =
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    ;
    const typed_output_schema =
        \\{"type":"object","properties":{"greeting":{"type":"string"}},"required":["greeting"]}
    ;

    const Tools = Registry(&.{.{
        .name = "hello_tool",
        .title = "Hello Tool",
        .description = "Say \"hello\" to a user.\nReturns JSON.",
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                _ = args;
                out.appendSlice(alloc, "{\"greeting\":\"hello\"}") catch {};
            }
        }.handler,
        .input_schema = typed_input_schema,
        .output_schema = typed_output_schema,
        .annotations = "{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true,\"openWorldHint\":false}",
        .icons = "[{\"src\":\"data:image/png;base64,AA==\",\"mimeType\":\"image/png\"}]",
    }});

    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"name\":\"hello_tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"title\":\"Hello Tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "Say \\\"hello\\\" to a user.\\nReturns JSON.") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"outputSchema\"") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"annotations\"") != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "\"icons\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, Tools.tools_list, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "raw schema ToolDef remains backwards-compatible" {
    const testing = std.testing;

    const raw_schema =
        \\{"name":"raw_tool","description":"Raw schema tool.","inputSchema":{"type":"object","properties":{},"required":[]}}
    ;
    const Tools = Registry(&.{.{
        .name = "raw_tool",
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                _ = args;
                out.appendSlice(alloc, "ok") catch {};
            }
        }.handler,
        .schema = raw_schema,
        .description = "ignored when schema is set",
    }});

    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, raw_schema) != null);
    try testing.expect(std.mem.indexOf(u8, Tools.tools_list, "ignored when schema is set") == null);
}

test "fromPackages composes package.mcp providers" {
    const testing = std.testing;

    const first_schema =
        \\{"name":"first","description":"First package tool.","inputSchema":{"type":"object","properties":{},"required":[]}}
    ;
    const second_schema =
        \\{"name":"second","description":"Second package tool.","inputSchema":{"type":"object","properties":{},"required":[]}}
    ;

    const FirstPackage = struct {
        pub fn mcp() ToolPack {
            return pack(&.{.{
                .name = "first",
                .handler = struct {
                    fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                        _ = args;
                        out.appendSlice(alloc, "one") catch {};
                    }
                }.handler,
                .schema = first_schema,
            }});
        }
    };
    const SecondPackage = struct {
        pub fn mcp() ToolPack {
            return pack(&.{.{
                .name = "second",
                .handler = struct {
                    fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                        _ = args;
                        out.appendSlice(alloc, "two") catch {};
                    }
                }.handler,
                .schema = second_schema,
            }});
        }
    };

    const Combined = fromPackages(.{ FirstPackage, SecondPackage });
    try testing.expectEqual(@as(usize, 2), Combined.count);
    try testing.expectEqual(@as(?usize, 0), Combined.parse("first"));
    try testing.expectEqual(@as(?usize, 1), Combined.parse("second"));
    try testing.expectEqualStrings("second", Combined.nameAt(1));
    try testing.expect(std.mem.indexOf(u8, Combined.tools_list, "\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, Combined.tools_list, "\"second\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    Combined.dispatch(testing.allocator, 0, &parsed.value.object, &out);
    try testing.expectEqualStrings("one", out.items);
}

test "fromPacks composes library tool packs" {
    const testing = std.testing;

    const first_schema =
        \\{"name":"first","description":"First test tool.","inputSchema":{"type":"object","properties":{},"required":[]}}
    ;
    const second_schema =
        \\{"name":"second","description":"Second test tool.","inputSchema":{"type":"object","properties":{},"required":[]}}
    ;

    const FirstLib = struct {
        pub const mcp_tools = pack(&.{.{
            .name = "first",
            .handler = struct {
                fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                    _ = args;
                    out.appendSlice(alloc, "one") catch {};
                }
            }.handler,
            .schema = first_schema,
        }});
    };
    const SecondLib = struct {
        pub const mcp_tools = pack(&.{.{
            .name = "second",
            .handler = struct {
                fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
                    _ = args;
                    out.appendSlice(alloc, "two") catch {};
                }
            }.handler,
            .schema = second_schema,
        }});
    };

    const Combined = fromPacks(.{ FirstLib.mcp_tools, SecondLib.mcp_tools });
    try testing.expectEqual(@as(usize, 2), Combined.count);
    try testing.expectEqual(@as(?usize, 0), Combined.parse("first"));
    try testing.expectEqual(@as(?usize, 1), Combined.parse("second"));
    try testing.expectEqualStrings("second", Combined.nameAt(1));
    try testing.expect(std.mem.indexOf(u8, Combined.tools_list, "\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, Combined.tools_list, "\"second\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    Combined.dispatch(testing.allocator, 1, &parsed.value.object, &out);
    try testing.expectEqualStrings("two", out.items);
}
