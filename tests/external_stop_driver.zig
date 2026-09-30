const std = @import("std");
const client = @import("client");
const c = client.sdk.c;

fn requestStop(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
    const stop: *std.atomic.Value(bool) = @ptrCast(@alignCast(parameter.?));
    c.Sleep(300);
    stop.store(true, .release);
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
    var stop = std.atomic.Value(bool).init(false);
    const thread = c.CreateThread(null, 0, requestStop, @ptrCast(&stop), 0, null);
    if (thread == null) return 4;
    defer _ = c.CloseHandle(thread);
    const result = client.engine.runClient(&options, &stop);
    if (c.WaitForSingleObject(thread, c.INFINITE) != c.WAIT_OBJECT_0) return 4;
    return @backingInt(result);
}
