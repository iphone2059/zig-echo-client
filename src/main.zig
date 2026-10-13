//! Program entry point, console signal handling and the process exit code.
//!
//! Nothing else lives here: the command line contract decides, the engine runs, and this file only
//! turns the result into a process status.

const std = @import("std");
const contract = @import("contract.zig");
const engine = @import("engine.zig");
const native = @import("native.zig");
const types = @import("types.zig");

const c = native.sdk.c;

fn consoleHandler(kind: c.DWORD) callconv(.winapi) c.BOOL {
    // CTRL_C_EVENT, CTRL_BREAK_EVENT and CTRL_CLOSE_EVENT all mean "stop the run now".
    if (kind == c.CTRL_C_EVENT or kind == c.CTRL_BREAK_EVENT or kind == c.CTRL_CLOSE_EVENT) {
        engine.requestStop();
        return c.TRUE;
    }
    return c.FALSE;
}

pub fn main(init: std.process.Init) u8 {
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    var options: types.Options = undefined;
    // A malformed command line reports the diagnostic and the usage on stderr, leaving stdout
    // empty, which is what the process tests read.
    if (!contract.parseProcessArgs(init.minimal.args, &options, &error_buffer)) {
        std.debug.print("Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)});
        std.debug.print("{s}", .{contract.usage});
        return @backingInt(types.ExitCode.usage);
    }
    // A valid help command line prints the usage on stdout and never starts the transport.
    if (options.help) {
        _ = native.diagnostics.writeStdout(contract.usage);
        return @backingInt(types.ExitCode.success);
    }
    engine.clearControl();
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) {
        std.debug.print("SetConsoleCtrlHandler failed: {d}\n", .{c.GetLastError()});
        return @backingInt(types.ExitCode.internal);
    }
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);
    return @backingInt(engine.runClient(&options));
}
