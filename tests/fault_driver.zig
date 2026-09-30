const std = @import("std");
const client = @import("client");
const engine = client.engine;
const c = client.sdk.c;

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return 2;
    if (args.len != 2) return 2;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "notify_failure")) engine.requireNotifySuccess(-1) else if (std.mem.eql(u8, mode, "corrupt_cq")) {
        _ = engine.requireDequeueCount(c.RIO_CORRUPT_CQ, 256);
    } else if (std.mem.eql(u8, mode, "invalid_transition")) {
        var armed = false;
        engine.requireNotificationDelivered(&armed);
    } else if (std.mem.eql(u8, mode, "control_post_failure")) engine.requireControlPost(c.FALSE, 5) else return 2;
    return 0;
}
