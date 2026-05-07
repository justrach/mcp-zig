const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_dep = b.dependency("mcp_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // This stands in for any dependency that exposes `pub fn mcp() mcp.registry.ToolPack`.
    const example_tools = b.createModule(.{
        .root_source_file = b.path("src/tool_package.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_tools.addImport("mcp", mcp_dep.module("mcp"));

    const exe = b.addExecutable(.{
        .name = "package-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/package_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
    exe.root_module.addImport("example_tools", example_tools);

    b.installArtifact(exe);
}
