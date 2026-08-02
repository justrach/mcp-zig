const std = @import("std");

const IoBackend = enum {
    threaded,
    evented,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const requested_backend = b.option(
        IoBackend,
        "io-backend",
        "Select std.Io backend for binaries: threaded or evented (Linux only for evented)",
    ) orelse .threaded;
    const evented_enabled = requested_backend == .evented and target.result.os.tag == .linux;

    const build_options = b.addOptions();
    build_options.addOption(bool, "evented_enabled", evented_enabled);

    // ── Library module (for consumers using mcp-zig as a dependency) ──────────
    const mcp_module = b.addModule("mcp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Standalone server executable ─────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "mcp-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false, // subscriptions/listen keep-alive uses a detached thread
            .strip = true, // smaller binary, faster page-in
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    // zig build run — start the server (useful for manual smoke-testing)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // 0.17: args after `--` are appended to run steps by the build runner itself.
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    // ── Client example executable ────────────────────────────────────────────
    const client_exe = b.addExecutable(.{
        .name = "mcp-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    client_exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(client_exe);

    // zig build run-client -- /path/to/server
    const run_client = b.addRunArtifact(client_exe);
    run_client.step.dependOn(b.getInstallStep());
    const run_client_step = b.step("run-client", "Run the MCP client example");
    run_client_step.dependOn(&run_client.step);

    // ── Package-provider example executable ──────────────────────────────────
    const example_tools = b.createModule(.{
        .root_source_file = b.path("examples/package-provider/src/tool_package.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_tools.addImport("mcp", mcp_module);

    const package_example = b.addExecutable(.{
        .name = "mcp-package-server-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/package-provider/src/package_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    package_example.root_module.addImport("mcp", mcp_module);
    package_example.root_module.addImport("example_tools", example_tools);

    const package_example_install = b.addInstallArtifact(package_example, .{});
    const package_example_step = b.step("package-example", "Build the package-provider example");
    package_example_step.dependOn(&package_example_install.step);

    // ── Cookbook example: a tiny kv-store product wrapped as MCP ────────────
    const cookbook = b.addExecutable(.{
        .name = "mcp-kv-store",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/kv-store/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cookbook.root_module.addImport("mcp", mcp_module);
    const cookbook_install = b.addInstallArtifact(cookbook, .{});
    const cookbook_step = b.step("cookbook", "Build the kv-store cookbook example");
    cookbook_step.dependOn(&cookbook_install.step);
}
