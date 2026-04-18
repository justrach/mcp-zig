const std = @import("std");
const build_options = @import("build_options");

const UseEvented = build_options.evented_enabled;

pub const Backend = enum {
    threaded,
    evented,
};

const Impl = if (UseEvented) ?std.Io.Evented else void;

pub const Runtime = struct {
    io_handle: std.Io,
    impl: Impl = if (UseEvented) null else {},

    pub fn init(gpa: std.mem.Allocator, init_ctx: std.process.Init) !Runtime {
        if (UseEvented) {
            var evented: std.Io.Evented = undefined;
            try evented.init(gpa, .{
                .argv0 = std.Io.Threaded.Argv0.init(init_ctx.minimal.args),
                .environ = init_ctx.minimal.environ,
            });
            return .{
                .io_handle = evented.io(),
                .impl = evented,
            };
        }

        return .{ .io_handle = init_ctx.io };
    }

    pub fn deinit(self: *Runtime) void {
        if (UseEvented) {
            self.impl.?.deinit();
        }
    }

    pub fn io(self: *const Runtime) std.Io {
        return self.io_handle;
    }

    pub fn backend(self: *const Runtime) Backend {
        _ = self;
        if (UseEvented) return .evented;
        return .threaded;
    }
};
