//! Starts a real run and asks it to stop from another thread, so the controlled-stop path is
//! exercised end to end rather than only through a unit-level flag.

const std = @import("std");
const client = @import("client");
const c = client.native.sdk.c;

fn requestStop(_: ?*anyopaque) callconv(.winapi) c.DWORD {
    // Late enough that the run has already entered its worker loop.
    c.Sleep(300);
    client.engine.requestStop();
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    if (argv.len != 2) return 1;
    const port = std.fmt.parseInt(u16, argv[1], 10) catch return 1;
    var options: client.types.Options = .{
        .protocol = .tcp,
        .pattern_kind = .binary_counter,
        .remote_port = port,
        .echo_count = 0,
        .timeout_seconds = 5,
        .pipeline_depth = 8,
        .pattern_bytes = 4096,
        .session_count = 1,
        .worker_count = 1,
        .stats = true,
    };
    const host = "127.0.0.1";
    for (host, 0..) |byte, index| options.host[index] = byte;
    options.host_len = host.len;
    const thread = c.CreateThread(null, 0, requestStop, null, 0, null);
    if (thread == null) return 4;
    defer _ = c.CloseHandle(thread);
    const result = client.engine.runClient(&options);
    if (c.WaitForSingleObject(thread, c.INFINITE) != c.WAIT_OBJECT_0) return 4;
    return @backingInt(result);
}
