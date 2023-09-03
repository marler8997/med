const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const CmdlineOpt = @import("CmdlineOpt.zig");
const platform = @import("platform.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    if (builtin.os.tag == .windows) {
        @import("win32.zig").fatal(null, fmt, args);
    } else {
        std.log.err(fmt, args);
        std.os.exit(0xff);
    }
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};
pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..], 0..) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !u8 {

    var cmdline_opt = CmdlineOpt{ };

    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        for (all_args) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else if (std.mem.eql(u8, arg, "--x11")) {
                if (build_options.enable_x11_backend) {
                    cmdline_opt.x11 = true;
                } else fatal("the x11 backend was not enabled in this build", .{});
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };

    if (args.len != 0)
        fatal("med currently doesn't accept any non-option command-line arguments", .{});

    // initialize something for now
    const width = 20;
    const height = 20;
    const engine = @import("engine.zig");
    engine.global_render.size = .{ .x = width, .y = height };
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    engine.global_render.rows = (try arena_instance.allocator().alloc([*]u8, height)).ptr;
    for (0 .. height) |y| {
        const row = try arena_instance.allocator().alloc(u8, width);
        for (0 .. width) |x| {
            row[x] = @intCast('a' + (x % 26));
        }
        engine.global_render.rows[y] = row.ptr;
    }

    try platform.go(cmdline_opt);
    return 0;
}
