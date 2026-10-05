const std = @import("std");
const c = @import("sdk.zig").c;
const types = @import("types.zig");
const options_mod = @import("cec_contract.zig");
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
    _ = win32.writeStdout(@import("cec_contract.zig").usage);
}

/// A malformed command line reports the diagnostic and the usage on stderr, leaving stdout empty.
fn helpError() void {
    std.debug.print("{s}", .{@import("cec_contract.zig").usage});
}

pub fn main(init: std.process.Init) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var error_buffer: [256]u8 = @splat(0);
    var options: types.Options = undefined;
    if (!options_mod.parseProcessArgs(init.minimal.args, arena_state.allocator(), &options, &error_buffer)) {
        std.debug.print("Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)});
        helpError();
        return @backingInt(types.ExitCode.usage);
    }
    if (options.help) {
        help();
        return 0;
    }
    stop_requested.store(false, .release);
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) {
        win32.report("SetConsoleCtrlHandler", c.GetLastError());
        return @backingInt(types.ExitCode.internal);
    }
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);
    return @backingInt(engine.runClient(&options, &stop_requested));
}

