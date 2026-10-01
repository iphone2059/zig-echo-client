const std = @import("std");
const client = @import("client");
const engine = client.engine;
const c = client.sdk.c;

fn finishedThread(_: ?*anyopaque) callconv(.winapi) c.DWORD {
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return 2;
    if (args.len != 2) return 2;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "notify_failure")) engine.requireNotifySuccess(-1) else if (std.mem.eql(u8, mode, "corrupt_cq")) {
        _ = engine.requireDequeueCount(c.RIO_CORRUPT_CQ, 256);
    } else if (std.mem.eql(u8, mode, "invalid_transition")) {
        var armed = false;
        engine.requireNotificationDelivered(&armed);
    } else if (std.mem.eql(u8, mode, "control_post_failure")) engine.requireControlPost(c.FALSE, 5) else if (std.mem.eql(u8, mode, "outstanding_release")) {
        var owner: client.engine_internal.WorkerResources = .{};
        owner.sessions = std.heap.page_allocator.alloc(client.engine_internal.Session, 1) catch return 2;
        owner.sessions[0] = .{ .outstanding = 1 };
        var worker: client.engine_internal.Worker = .{};
        worker.resources = &owner;
        worker.thread = c.CreateThread(null, 0, finishedThread, null, 0, null);
        if (worker.thread == null) return 2;
        owner.thread.reset(worker.thread);
        engine.destroyWorker(&worker);
    } else if (std.mem.eql(u8, mode, "outstanding_cq_retirement")) {
        var sessions: [1]client.engine_internal.Session = .{.{ .outstanding = 1 }};
        var worker: client.engine_internal.Worker = .{};
        worker.sessions = &sessions;
        worker.session_count = 1;
        engine.retireCompletionQueue(&worker);
    } else return 2;
    return 0;
}
