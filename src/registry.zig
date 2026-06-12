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
            inline for (info.params, 0..) |param, i| {
                const name_str = param_names[i];
                const T = param.type.?;

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
                    const R = @TypeOf(result);
                    if (R == []const u8 or R == []u8) {
                        out.appendSlice(alloc, result) catch {};
                    }
                } else |err| {
                    out.appendSlice(alloc, "error: ") catch {};
                    out.appendSlice(alloc, @errorName(err)) catch {};
                }
            } else {
                const result = @call(.auto, func, params);
                if (ReturnType == []const u8 or ReturnType == []u8) {
                    out.appendSlice(alloc, result) catch {};
                }
                // void return: nothing to write
            }
        }
    }.handler;
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
