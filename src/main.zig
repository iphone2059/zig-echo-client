const std = @import("std");
const c = @import("sdk.zig").c;
const types = @import("types.zig");
const options_mod = @import("options.zig");
const win32 = @import("win32.zig");
const engine = @import("engine.zig");

var stop_requested = std.atomic.Value(bool).init(false);

fn consoleHandler(kind: c.DWORD) callconv(.winapi) c.BOOL {
    if (kind == c.CTRL_C_EVENT or kind == c.CTRL_BREAK_EVENT or kind == c.CTRL_CLOSE_EVENT) {
        stop_requested.store(true, .release);
        return c.TRUE;
    }
    return c.FALSE;
}

fn help() void {
    std.debug.print(
        "Usage: zig-echo-client target /p tcp|udp [/r port] [/l port] [/n count] [/t seconds]\n" ++
            "       [/i ms] [/d text | /z bytes | /zt bytes] [/k depth] [/c sessions] [/threads workers]\n" ++
            "       [/w seconds] [/rc [seconds]] [/report seconds] [/b bytes] [/cq capacity]\n" ++
            "       [/memory bytes] [/q] [/stats]\n",
        .{},
    );
}

pub fn main(init: std.process.Init) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var error_buffer: [256]u8 = @splat(0);
    var options: types.Options = undefined;
    if (!options_mod.parseProcessArgs(init.minimal.args, arena_state.allocator(), &options, &error_buffer)) {
        std.debug.print("Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)});
        help();
        return @backingInt(types.ExitCode.usage);
    }
    if (options.help) {
        help();
        return 0;
    }
    stop_requested.store(false, .release);
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) return @backingInt(types.ExitCode.internal);
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);
    return @backingInt(engine.runClient(&options, &stop_requested));
}
