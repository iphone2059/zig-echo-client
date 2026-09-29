const std = @import("std");
const c = @import("sdk.zig").c;
const types = @import("types.zig");
const options_mod = @import("options.zig");
const win32 = @import("win32.zig");
const rio = @import("rio.zig");
const udp = @import("udp.zig");

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
        "Usage: zig-echo-client target /p udp [/r port] [/l port] [/n count] [/t seconds]\n" ++
        "       [/i ms] [/d text | /z bytes | /zt bytes] [/c sessions] [/threads workers] [/w seconds]\n" ++
        "       [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
        "This code drop implements the RIO/IOCP UDP path. TCP/ConnectEx is not replaced by a fallback.\n",
        .{},
    );
}

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var error_buffer: [256]u8 = [_]u8{0} ** 256;
    const options = options_mod.parse(arena_state.allocator(), &error_buffer) catch {
        std.debug.print("Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)});
        help();
        return @intFromEnum(types.ExitCode.usage);
    };
    if (options.help) { help(); return 0; }
    if (options.protocol != .udp) {
        std.debug.print("TCP is intentionally unavailable in this first code slice; no std.net/send/recv fallback is used.\n", .{});
        return @intFromEnum(types.ExitCode.usage);
    }
    stop_requested.store(false, .release);
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) return @intFromEnum(types.ExitCode.internal);
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);
    var winsock = win32.Winsock.init() catch return @intFromEnum(types.ExitCode.network);
    defer winsock.deinit();
    var api = rio.Api.load() catch return @intFromEnum(types.ExitCode.network);
    return @intFromEnum(udp.run(&api, &options, &stop_requested));
}
