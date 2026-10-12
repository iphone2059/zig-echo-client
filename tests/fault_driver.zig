//! Drives the engine's named fail-fast boundaries in a child process.
//!
//! Every mode must terminate the process with the internal exit code, leave stdout empty and put the
//! boundary's own stage name on stderr. That is exactly what a live run does when the same invariant
//! breaks, so the driver never needs a second implementation of the check.

const std = @import("std");
const client = @import("client");
const engine = client.engine;
const c = client.native.sdk.c;
const Slot = client.native.transport.Slot;
const Worker = client.worker.Worker;

/// A worker that owns nothing but one session's native accounting, which is what the release
/// preconditions inspect.
fn workerWithOutstanding(outstanding: u32) struct { worker: Worker, slots: [1]Slot } {
    return .{
        .worker = undefined,
        .slots = .{.{ .receive_outstanding = outstanding }},
    };
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return 2;
    if (args.len != 2) return 2;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "notify_failure")) {
        engine.requireNotifySuccess(-1);
    } else if (std.mem.eql(u8, mode, "corrupt_cq")) {
        _ = engine.requireDequeueCount(c.RIO_CORRUPT_CQ, 256);
    } else if (std.mem.eql(u8, mode, "invalid_transition")) {
        var armed = false;
        engine.requireNotificationDelivered(&armed);
    } else if (std.mem.eql(u8, mode, "control_post_failure")) {
        engine.requireControlPost(c.FALSE, 5);
    } else if (std.mem.eql(u8, mode, "outstanding_release")) {
        var held = workerWithOutstanding(1);
        held.worker = .{};
        held.worker.transport.slots = &held.slots;
        held.worker.core.session_count = 1;
        held.worker.release(std.heap.page_allocator);
    } else if (std.mem.eql(u8, mode, "outstanding_cq_retirement")) {
        var held = workerWithOutstanding(1);
        held.worker = .{};
        held.worker.transport.slots = &held.slots;
        held.worker.core.session_count = 1;
        engine.retireCompletionQueue(&held.worker);
    } else return 2;
    return 0;
}
