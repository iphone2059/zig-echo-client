//! Client engine tests: completion arbitration, generation retirement, registered-memory geometry,
//! the timer heap against a reference model, and the exact Windows ABI.

const std = @import("std");
const client = @import("client");
const native = client.native;
const metrics = client.metrics;
const c = native.sdk.c;
const engine = client.engine;
const timer = client.timer;
const scheduler = client.scheduler;
const Session = client.session.Session;
const Worker = client.worker.Worker;

fn testClock() native.clock.Clock {
    return native.clock.Clock.init() orelse @panic("QueryPerformanceFrequency failed");
}

/// Builds a worker record that owns only host memory, so a state-machine test never touches a
/// registered buffer or a completion port it did not create.
/// Reports both native operations of an attempt the way the provider delivers a verified echo: the
/// send completes first, then the receive. The settlement happens on the second one.
fn verifiedEcho(core: *client.worker.Core, index: u32, now: u64, out: []scheduler.Step) []const scheduler.Step {
    const bytes: usize = core.sessions[index].attempt_bytes;
    // One buffer pair wide enough for the largest attempt these cases build, and the bound is
    // checked rather than assumed so an oversized case fails loudly instead of slicing past the end.
    var expected: [32 * 1024]u8 = @splat(0xAB);
    var echoed: [32 * 1024]u8 = @splat(0xAB);
    if (bytes > expected.len) return out[0..0];
    const sent = scheduler.onSent(core, index, now, out);
    const received = scheduler.onReceived(core, index, echoed[0..bytes], expected[0..bytes], now, out[sent.len..]);
    return out[0 .. sent.len + received.len];
}

fn buildWorker(
    sessions: []Session,
    slots: []client.native.transport.Slot,
    steps: []scheduler.Step,
    nodes: []timer.Node,
    positions: []u32,
    options: *const client.types.Options,
    payload_bytes: usize,
) Worker {
    var worker: Worker = .{};
    worker.core.options = options;
    worker.core.payload_bytes = payload_bytes;
    worker.core.session_count = @intCast(sessions.len);
    worker.core.live_sessions = @intCast(sessions.len);
    worker.core.sessions = sessions;
    worker.transport.slots = slots;
    for (slots) |*slot| slot.* = .{ .generation = 1 };
    worker.core.steps = steps;
    worker.core.timer_nodes = nodes;
    worker.core.timer_positions = positions;
    worker.core.timers = timer.Heap.init(nodes, positions) catch @panic("timer heap capacity");
    worker.clock = testClock();
    worker.core.ticks_per_second = worker.clock.frequency;
    worker.core.timeout_ticks = worker.clock.millisecondsToTicks(5_000);
    for (sessions, 0..) |*entry, index| {
        entry.* = .{};
        entry.index = @intCast(index);
    }
    return worker;
}

var notification_trace: [8]u8 = @splat(0);
var notification_trace_len: usize = 0;

fn fakeDequeue(_: c.RIO_CQ, _: [*c]c.RIORESULT, _: c.ULONG) callconv(.winapi) c.ULONG {
    notification_trace[notification_trace_len] = 'D';
    notification_trace_len += 1;
    return 0;
}

fn fakeNotify(_: c.RIO_CQ) callconv(.winapi) c_int {
    notification_trace[notification_trace_len] = 'N';
    notification_trace_len += 1;
    return c.ERROR_SUCCESS;
}

test "client RIO notification drains its queue before one rearm" {
    var api = native.rio.Api{ .table = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE) };
    api.table.RIODequeueCompletion = fakeDequeue;
    api.table.RIONotify = fakeNotify;
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{};
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 1);
    worker.transport.api = &api;
    worker.transport.completion_queue = .{ .api = &api, .value = @as(c.RIO_CQ, @ptrFromInt(0x1000)), .armed = false };
    slots[0].receive_outstanding = 1;
    worker.transport.rio_outstanding = 1;
    worker.transport.total_outstanding = 1;
    notification_trace_len = 0;
    // The queue is only armed while work is in flight.
    engine.maybeArm(&worker);
    try std.testing.expect(worker.transport.completion_queue.armed);
    // A second arm while one is already outstanding is an internal contradiction, so the helper
    // must not emit another notification.
    engine.maybeArm(&worker);
    // A delivery clears the armed state, then the queue is drained, then it is armed again.
    engine.requireNotificationDelivered(&worker.transport.completion_queue.armed);
    engine.drainRio(.tcp, &worker, 4);
    engine.maybeArm(&worker);
    try std.testing.expectEqualStrings("NDN", notification_trace[0..notification_trace_len]);
    try std.testing.expect(worker.transport.completion_queue.armed);
    // With nothing outstanding the queue stays unarmed, which is what keeps a notification from
    // outliving the work it describes.
    slots[0].receive_outstanding = 0;
    worker.transport.rio_outstanding = 0;
    worker.transport.total_outstanding = 0;
    engine.requireNotificationDelivered(&worker.transport.completion_queue.armed);
    engine.maybeArm(&worker);
    try std.testing.expectEqualStrings("NDN", notification_trace[0..notification_trace_len]);
    try std.testing.expect(!worker.transport.completion_queue.armed);
}

test "client per-session quota trims the last batch to the remaining grant" {
    var sessions: [2]Session = .{ .{}, .{} };
    var slots: [2]client.native.transport.Slot = @splat(.{});
    var steps: [6]scheduler.Step = undefined;
    var nodes: [2]timer.Node = undefined;
    var positions: [2]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .echo_count = 17, .pipeline_depth = 8, .session_count = 2 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 4_096);
    const started = worker.clock.nowTicks();
    const connects = scheduler.start(&worker.core, started, &steps);
    try std.testing.expectEqual(@as(usize, 2), connects.len);
    // The first attempt of a generation is immediate and takes a whole pipeline batch.
    const first = scheduler.onConnected(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(@as(u64, 8), sessions[0].requested_echoes);
    // A settled attempt starts the next one; the last batch is trimmed, never refused.
    _ = verifiedEcho(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(u64, 8), sessions[0].requested_echoes);
    _ = verifiedEcho(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(u64, 1), sessions[0].requested_echoes);
    try std.testing.expectEqual(@as(u64, 17), worker.core.statistics.attempted);
    try std.testing.expectEqual(@as(u64, 16), sessions[0].settled);
    const exhausted = verifiedEcho(&worker.core, 0, started, &steps);
    // The quota is spent, so the generation is retired instead of being left open: a session with
    // nothing left to echo must not hold a socket the peer can never close.
    try std.testing.expectEqual(@as(usize, 1), exhausted.len);
    try std.testing.expectEqual(client.session.State.closing, sessions[0].state);
    _ = scheduler.onGenerationDrained(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(client.session.State.done, sessions[0].state);
    // The quota switch is per session, so the second session's ledger is untouched.
    try std.testing.expectEqual(@as(u64, 0), sessions[1].claimed);
    try std.testing.expectEqual(@as(u64, 17), worker.core.statistics.attempted);
}

test "client latency sample is one completed batch" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 4 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);
    sessions[0].attempt_started_ticks = started -| worker.clock.millisecondsToTicks(2);
    _ = verifiedEcho(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.latency_samples);
    try std.testing.expect(worker.core.statistics.latency_samples == worker.core.statistics.sampleCount());
    try std.testing.expectEqual(@as(u64, 4), worker.core.statistics.echoes);
    try std.testing.expectEqual(@as(u64, 64), worker.core.statistics.bytes);
}

test "client partial RIOSend completion reposts only the unsent tail" {
    var winsock = try native.winsock.Winsock.init();
    defer winsock.deinit();
    const extensions = try native.rio.Extensions.load();
    var api = extensions.rio;
    api.table.RIOSend = recordingSend;
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 100);
    worker.transport.api = &api;
    worker.transport.arena = try native.arena.Arena.create(&extensions.rio, 1, 128);
    defer worker.transport.arena.deinit();
    sessions[0].state = .active;
    sessions[0].attempt_bytes = 100;
    slots[0].send_outstanding = 1;
    slots[0].send_posted_bytes = 100;
    worker.transport.rio_outstanding = 1;
    worker.transport.total_outstanding = 1;
    // The injected completion bypasses the notification delivery helper. The original accepted
    // send has already armed its queue, so reposting its tail must not arm an absent native CQ.
    worker.transport.completion_queue.armed = true;
    sent_offset = 0;
    sent_length = 0;
    const context = native.completion.encode(0, 1, native.completion.no_send_slot, .send).?;
    engine.handleRioResult(.tcp, &worker, .{
        .Status = 0,
        .BytesTransferred = 40,
        .SocketContext = null,
        .RequestContext = context,
    });
    try std.testing.expectEqual(@as(u32, 40), slots[0].send_offset);
    // The remainder is re-posted from the same registered window, so the offset moves and the
    // registration does not.
    try std.testing.expectEqual(@as(u32, 40), sent_offset);
    try std.testing.expectEqual(@as(u32, 60), sent_length);
    try std.testing.expectEqual(@as(u32, 1), slots[0].send_outstanding);
    try std.testing.expectEqual(@as(u64, 40), worker.core.statistics.sent_bytes);
}

var sent_offset: u32 = 0;
var sent_length: u32 = 0;

fn recordingSend(_: c.RIO_RQ, buffers: [*c]c.RIO_BUF, count: c.ULONG, _: c.DWORD, _: ?*anyopaque) callconv(.winapi) c.BOOL {
    if (count != 1) return c.FALSE;
    sent_offset = buffers[0].Offset;
    sent_length = buffers[0].Length;
    return c.TRUE;
}

test "client close waits for both posted completions before the generation drains" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    worker.core.drain_grace_ticks = worker.clock.millisecondsToTicks(5_000);
    const started = worker.clock.nowTicks();
    sessions[0].state = .active;
    sessions[0].requested_echoes = 8;
    slots[0].send_outstanding = 1;
    slots[0].send_posted_bytes = 128;
    slots[0].receive_outstanding = 1;
    slots[0].receive_posted_bytes = 128;
    worker.transport.rio_outstanding = 2;
    worker.transport.total_outstanding = 2;
    const closing = scheduler.onTransportFailure(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(usize, 1), closing.len);
    try std.testing.expectEqual(client.session.State.closing, sessions[0].state);
    try std.testing.expectEqual(@as(u64, 8), worker.core.statistics.lost);
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.network_errors);
    var transport = engine.RioAdapter(.tcp){ .transport = &worker.transport, .options = &options, .clock = &worker.clock };
    _ = transport.close(0);
    // Closing the socket starts cancellation; it does not end the lifetime of the pending I/O, so
    // the generation may not be released until every completion has been dequeued.
    const send_context = native.completion.encode(0, 1, native.completion.no_send_slot, .send).?;
    engine.handleRioResult(.tcp, &worker, .{
        .Status = 0,
        .BytesTransferred = 0,
        .SocketContext = null,
        .RequestContext = send_context,
    });
    try std.testing.expectEqual(client.session.State.closing, sessions[0].state);
    try std.testing.expectEqual(@as(u64, 8), worker.core.statistics.lost);
    const receive_context = native.completion.encode(0, 1, native.completion.no_send_slot, .receive).?;
    engine.handleRioResult(.tcp, &worker, .{
        .Status = 0,
        .BytesTransferred = 0,
        .SocketContext = null,
        .RequestContext = receive_context,
    });
    try std.testing.expectEqual(client.session.State.done, sessions[0].state);
    try std.testing.expectEqual(@as(u32, 0), worker.transport.outstanding());
    // The failed attempt's quota is spent exactly once.
    try std.testing.expectEqual(@as(u64, 8), worker.core.statistics.lost);
}

test "client closing generation completions never steer the live state machine" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    sessions[0].state = .active;
    sessions[0].requested_echoes = 4;
    slots[0].send_outstanding = 1;
    slots[0].send_posted_bytes = 16;
    worker.transport.rio_outstanding = 1;
    worker.transport.total_outstanding = 1;
    slots[0].closing = true;
    // This slot still owns the closing generation; no replacement has been created. Retiring
    // its real request must not resume an active business snapshot or count cancelled bytes.
    const stale = native.completion.encode(0, 1, native.completion.no_send_slot, .send).?;
    engine.handleRioResult(.tcp, &worker, .{
        .Status = 0,
        .BytesTransferred = 16,
        .SocketContext = null,
        .RequestContext = stale,
    });
    try std.testing.expectEqual(@as(u32, 0), slots[0].send_outstanding);
    try std.testing.expect(sessions[0].state == .active);
    try std.testing.expect(!sessions[0].send_done);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.sent_bytes);
}

test "client worker rolls back every acquired stage before publication" {
    var winsock = try native.winsock.Winsock.init();
    defer winsock.deinit();
    const extensions = try native.rio.Extensions.load();
    const options = client.types.Options{ .protocol = .tcp, .cq_capacity = 4096 };
    const remote: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    const pattern = [_]u8{0x41};
    const clock = testClock();
    const cases = [_]struct { stage: engine.InitStage, expected: anyerror }{
        .{ .stage = .port, .expected = error.Port },
        .{ .stage = .arena, .expected = error.Arena },
        .{ .stage = .sessions, .expected = error.Sessions },
        .{ .stage = .timer_nodes, .expected = error.TimerNodes },
        .{ .stage = .timer_positions, .expected = error.TimerPositions },
        .{ .stage = .timer_heap, .expected = error.TimerHeap },
        .{ .stage = .completion_queue, .expected = error.CompletionQueue },
    };
    defer engine.test_fail_stage = null;
    for (cases) |case| {
        var worker: Worker = .{};
        engine.test_fail_stage = case.stage;
        try std.testing.expectError(case.expected, engine.initializeWorker(.tcp, &worker, &extensions, &options, &remote, &pattern, 1, 1, 1024 * 1024, 0, &clock, null));
        // Every stage that had already been acquired has been released, so a failed worker owns
        // nothing at all.
        try std.testing.expect(worker.transport.port.value == null);
        try std.testing.expect(worker.transport.arena.pages.pointer == null);
        try std.testing.expectEqual(@as(usize, 0), worker.core.sessions.len);
        try std.testing.expectEqual(@as(usize, 0), worker.core.steps.len);
        try std.testing.expectEqual(@as(usize, 0), worker.core.timer_nodes.len);
        try std.testing.expectEqual(@as(usize, 0), worker.core.timer_positions.len);
        try std.testing.expect(!worker.transport.completion_queue.valid());
    }
}

test "client release barrier requires every completion retired" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    sessions[0].state = .done;
    try std.testing.expectEqual(@as(u32, 0), worker.transport.outstanding());
    try std.testing.expect(sessions[0].isFinished());
    // The named boundary itself is exercised by the fault driver, which must terminate the process.
    slots[0].receive_outstanding = 1;
    worker.transport.rio_outstanding = 1;
    worker.transport.total_outstanding = 1;
    try std.testing.expectEqual(@as(u32, 1), worker.transport.outstanding());
}

test "client arena registers independent send and receive windows per slot" {
    var winsock = try native.winsock.Winsock.init();
    defer winsock.deinit();
    const extensions = try native.rio.Extensions.load();
    var arena = try native.arena.Arena.create(&extensions.rio, 4, 256);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 4), arena.send_registrations.len);
    for (arena.receive_registrations) |registration| try std.testing.expect(registration.valid());
    try std.testing.expectEqual(@as(usize, 4 * 256), arena.receive_offset);
    try std.testing.expectEqual(@as(usize, 4 * 256 * 2), arena.bytes);
    // The documented RIOSend contract forbids sharing any part of a registration with another
    // pending send, so every TX window must own a distinct registration.
    for (arena.send_registrations, 0..) |registration, index| {
        try std.testing.expect(registration.valid());
        for (arena.send_registrations[index + 1 ..]) |other| {
            try std.testing.expect(registration.id != other.id);
        }
        for (arena.receive_registrations) |receive_registration| {
            try std.testing.expect(registration.id != receive_registration.id);
        }
    }
    // Views are bounds-checked against the slot stride instead of silently aliasing a neighbour.
    try std.testing.expect(arena.receiveView(3, 256) != null);
    try std.testing.expect(arena.receiveView(3, 257) == null);
    try std.testing.expect(arena.receiveView(4, 16) == null);
    try std.testing.expect(arena.sendViewFrom(0, 200, 56) != null);
    try std.testing.expect(arena.sendViewFrom(0, 200, 57) == null);
    try std.testing.expect(arena.sendBytes(0, 256) != null);
    try std.testing.expect(arena.sendBytes(4, 256) == null);
}

test "client native owners transfer reset and destroy exactly once" {
    var sock: native.socket.Socket = .{};
    try std.testing.expectEqual(c.INVALID_SOCKET, sock.get());
    try std.testing.expectEqual(c.INVALID_SOCKET, sock.take());
    sock.reset(c.INVALID_SOCKET);
    sock.deinit();
    var kernel: native.handle.Handle = .{};
    try std.testing.expect(kernel.get() == null);
    kernel.reset(null);
    kernel.deinit();
    var memory = try native.arena.VirtualMemory.alloc(4_096);
    memory.deinit();
    memory.deinit();
    try std.testing.expect(memory.pointer == null);
}

test "client registered sockets require overlapped RIO and the ABI is exact" {
    try std.testing.expectEqual(c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO, native.socket.registeredFlags());
    try std.testing.expectEqual(@as(u32, 0x00000004), c.RIO_MSG_WAITALL);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.RIO_BUF));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.RIORESULT));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.OVERLAPPED));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.RIO_NOTIFICATION_COMPLETION));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE));
}

test "client loads the complete RIO table and ConnectEx" {
    var empty: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
    try std.testing.expect(!native.rio.Api.tableComplete(&empty));
    var winsock = try native.winsock.Winsock.init();
    defer winsock.deinit();
    const extensions = try native.rio.Extensions.load();
    try std.testing.expect(native.rio.Api.tableComplete(&extensions.rio.table));
    try std.testing.expect(extensions.connect_ex != null);
}

test "client closes an idle completion queue that is armed with a queued notification" {
    var winsock = try native.winsock.Winsock.init();
    defer winsock.deinit();
    const api = try native.rio.Api.load();
    var worker: Worker = .{};
    defer worker.release(std.heap.page_allocator);
    worker.transport.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    try std.testing.expect(worker.transport.port.value != null);
    worker.transport.api = &api;
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = worker.transport.port.get();
    notification.Iocp.CompletionKey = @ptrCast(&worker);
    notification.Iocp.Overlapped = @ptrCast(&worker.transport.notification_overlapped);
    worker.transport.completion_queue.reset(&api, api.createCq(8, &notification));
    try std.testing.expect(worker.transport.completion_queue.valid());
    try std.testing.expectEqual(@as(c_int, c.ERROR_SUCCESS), api.notify(worker.transport.completion_queue.value));
    worker.transport.completion_queue.armed = true;
    try std.testing.expect(c.PostQueuedCompletionStatus(worker.transport.port.get(), 0, @intFromPtr(&worker), &worker.transport.notification_overlapped) != c.FALSE);
    engine.retireCompletionQueue(&worker);
    try std.testing.expectEqual(c.RIO_INVALID_CQ, worker.transport.completion_queue.value);
    try std.testing.expect(!worker.transport.completion_queue.armed);
}

test "client request contexts round trip and reject forged values" {
    const send = native.completion.encode(3, 7, native.completion.no_send_slot, .send) orelse return error.TestUnexpectedResult;
    const decoded = native.completion.decode(@intFromPtr(send)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), decoded.index);
    try std.testing.expectEqual(@as(u32, 7), decoded.generation);
    try std.testing.expectEqual(native.completion.Operation.send, decoded.operation);
    // A zero context, a bit above the canonical payload, and a receive carrying a send slot are all
    // rejected rather than masked into a live request.
    try std.testing.expect(native.completion.decode(0) == null);
    try std.testing.expect(native.completion.decode(@as(usize, 1) << 47) == null);
    try std.testing.expect(native.completion.encode(1, 1, 3, .receive) == null);
    try std.testing.expect(native.completion.encode(1, 0, 0, .receive) == null);
    // The generation wraps rather than saturating: it is only ever reused once the previous one has
    // fully drained, so wrapping back to one cannot alias a live request.
    try std.testing.expectEqual(@as(u32, 1), native.completion.nextGeneration(native.completion.maximum_generation));
    try std.testing.expectEqual(@as(u32, 2), native.completion.nextGeneration(1));
}

fn xorshift(state: *u32) u32 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    state.* = value;
    return value;
}

test "client timer agrees with a fixed-seed 100000-operation reference model" {
    const capacity = 64;
    var nodes: [capacity]timer.Node = undefined;
    var positions: [capacity]u32 = undefined;
    var active: [capacity]bool = @splat(false);
    var deadlines: [capacity]u64 = @splat(0);
    var heap = try timer.Heap.init(&nodes, &positions);
    var random_state: u32 = 0x57a9c431;
    for (0..100000) |step| {
        const action = xorshift(&random_state) & 3;
        const index: u32 = xorshift(&random_state) % capacity;
        const now: u64 = step % 4096;
        if (action <= 1) {
            const deadline = xorshift(&random_state) % 4096;
            try std.testing.expect(heap.insertOrUpdate(index, deadline));
            active[index] = true;
            deadlines[index] = deadline;
        } else if (action == 2) {
            try std.testing.expectEqual(active[index], heap.remove(index));
            active[index] = false;
        } else {
            var expected: ?u32 = null;
            var best: u64 = 0;
            for (active, deadlines, 0..) |is_active, deadline, candidate| {
                if (is_active and deadline <= now and (expected == null or deadline < best or
                    (deadline == best and candidate < expected.?)))
                {
                    expected = @intCast(candidate);
                    best = deadline;
                }
            }
            try std.testing.expectEqual(expected, heap.popExpired(now));
            if (expected) |popped| active[popped] = false;
        }
        var count: u32 = 0;
        for (active, deadlines, 0..) |is_active, deadline, candidate| {
            if (!is_active) {
                try std.testing.expectEqual(timer.invalid_position, positions[candidate]);
                continue;
            }
            count += 1;
            try std.testing.expect(positions[candidate] < heap.len);
            try std.testing.expectEqual(@as(u32, @intCast(candidate)), nodes[positions[candidate]].index);
            try std.testing.expectEqual(deadline, nodes[positions[candidate]].deadline);
        }
        try std.testing.expectEqual(count, heap.len);
    }
}

test "client terminal line keeps the reference field order" {
    var statistics = metrics.Statistics{};
    statistics.attempted = 5;
    statistics.echoes = 3;
    statistics.elapsed_ms = 10;
    var buffer: [1024]u8 = undefined;
    const line = statistics.writeLine("final", 2, 1, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, line, "final elapsed_ms=10 sessions=2 active=1 attempted=5 pending=2 echoed=3 corrupted=0 lost=0 cancelled=0 "));
    try std.testing.expect(std.mem.indexOf(u8, line, "sent_bytes=0 received_bytes=0 bytes=0 connections=0 reconnects=0 network_errors=0 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "mean_us=0") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "latency_sample=batch\n"));
}

test "client worker resolution covers every session without empty workers" {
    for (1..8) |workers| {
        for (1..40) |sessions| {
            const count: u32 = @intCast(sessions);
            const resolved = client.contract.resolveWorkerCount(@intCast(workers), count);
            try std.testing.expect(resolved >= 1 and resolved <= count);
            const base = count / resolved;
            const extra = count % resolved;
            var total: u32 = 0;
            for (0..resolved) |index| total += @intCast(base + @intFromBool(index < extra));
            try std.testing.expectEqual(count, total);
        }
    }
}

test "a closing generation that never drains is fatal" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    worker.core.drain_grace_ticks = worker.clock.millisecondsToTicks(5_000);
    const started = worker.clock.nowTicks();
    sessions[0].state = .active;
    sessions[0].requested_echoes = 1;
    // One operation stays in flight, so the generation can never drain on its own.
    slots[0].receive_outstanding = 1;
    worker.transport.rio_outstanding = 1;
    worker.transport.total_outstanding = 1;
    const closing = scheduler.onTransportFailure(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(usize, 1), closing.len);
    try std.testing.expectEqual(client.session.State.closing, sessions[0].state);
    // Before the grace expires the slot is simply waiting.
    _ = scheduler.poll(&worker.core, started, &steps);
    try std.testing.expect(!worker.core.statistics.fatal);
    // Once it expires the run is broken rather than stranded in Closing forever.
    _ = scheduler.poll(&worker.core, started +| worker.core.drain_grace_ticks +| 1, &steps);
    try std.testing.expect(worker.core.statistics.fatal);
}

test "a reconnect is counted at the failure that triggers it" {
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .reconnect_seconds = 1 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 16);
    worker.core.reconnect_enabled = true;
    worker.core.reconnect_ticks = worker.clock.millisecondsToTicks(1_000);
    worker.core.drain_grace_ticks = worker.clock.millisecondsToTicks(5_000);
    const started = worker.clock.nowTicks();
    sessions[0].state = .active;
    sessions[0].requested_echoes = 4;
    _ = scheduler.onTransportFailure(&worker.core, 0, started, &steps);
    // The tally moves with the failure, not with the timer that later opens the new generation, so
    // a stop arriving during the wait cannot change it.
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.reconnects);
    try std.testing.expect(sessions[0].reconnect_after_close);
}

/// Counts the steps of one tag, which is how the reference tests assert a sequence without
/// depending on the order the scheduler happened to build it in.
fn countSteps(steps: []const scheduler.Step, comptime tag: std.meta.Tag(scheduler.Step)) usize {
    var total: usize = 0;
    for (steps) |step| {
        if (std.meta.activeTag(step) == tag) total += 1;
    }
    return total;
}

test "a receive completion waits for the send before settling the attempt" {
    // Mirrors the reference's receive_completion_waits_for_send_before_settling_the_attempt: a
    // receive that lands first must not account anything until its send retires, because the
    // settlement is what turns a batch into echoes.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 2 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);

    var buffer: [12]u8 = @splat(0xAB);
    const before_send = scheduler.onReceived(&worker.core, 0, &buffer, &buffer, started, &steps);
    try std.testing.expectEqual(@as(usize, 0), before_send.len);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.echoes);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.bytes);
    // The attempt is still in flight, so its deadline stays armed.
    try std.testing.expect(sessions[0].deadline_ticks != 0);

    _ = scheduler.onSent(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(u64, 2), worker.core.statistics.echoes);
}

test "a receive may complete before the send without posting a second attempt" {
    // Mirrors receive_may_complete_before_send_without_posting_a_second_attempt: RIO completion
    // ordering between send and receive is not a business ordering guarantee, so a verified echo
    // that arrives first must be held rather than starting a second attempt.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 1 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    const initial = scheduler.onConnected(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(usize, 1), countSteps(initial, .send));
    try std.testing.expectEqual(@as(usize, 1), countSteps(initial, .receive));

    var buffer: [6]u8 = @splat(0xAB);
    const after_receive = scheduler.onReceived(&worker.core, 0, &buffer, &buffer, started, &steps);
    try std.testing.expectEqual(@as(usize, 0), countSteps(after_receive, .send));
    try std.testing.expect(sessions[0].attempt_bytes != 0);

    const after_send = scheduler.onSent(&worker.core, 0, started, &steps);
    try std.testing.expect(countSteps(after_send, .send) >= 1);
}

test "a short datagram is corrupted rather than reassembled as stream data" {
    // Mirrors udp_short_datagram_is_not_reassembled_as_tcp_stream_data. UDP is message oriented, so a
    // datagram shorter than the attempt is a corrupted echo and never the first half of the next one.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .udp, .pipeline_depth = 1, .echo_count = 1 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);
    _ = scheduler.onSent(&worker.core, 0, started, &steps);

    var echoed: [3]u8 = @splat(0xAB);
    var expected: [6]u8 = @splat(0xAB);
    const settled = scheduler.onReceived(&worker.core, 0, &echoed, &expected, started, &steps);
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.corrupted);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.echoes);
    // The quota is spent, so this is the last attempt and the generation is retired.
    try std.testing.expectEqual(@as(usize, 1), countSteps(settled, .close));
}

test "a corrupted receive settles the batch once and continues the quota" {
    // Mirrors corrupted_receive_settles_the_batch_and_continues_the_quota. Integrity is counted per
    // attempt: this attempt carried two echo units and is settled as corrupted alone, because
    // counting it lost as well would settle one attempt twice.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 2, .reconnect_seconds = 1 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);
    _ = scheduler.onSent(&worker.core, 0, started, &steps);

    // Corruption is a content mismatch, not a short read: the lengths agree with the attempt and the
    // bytes differ, which is the case this reference sequence is about.
    var echoed: [12]u8 = @splat(0xCD);
    var expected: [12]u8 = @splat(0xAB);
    const next = scheduler.onReceived(&worker.core, 0, &echoed, &expected, started, &steps);
    // The next attempt is one whole batch, and the receive is posted before the send.
    try std.testing.expectEqual(@as(usize, 1), countSteps(next, .receive));
    try std.testing.expectEqual(@as(usize, 1), countSteps(next, .send));
    try std.testing.expectEqual(@as(u64, 2), worker.core.statistics.corrupted);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.lost);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.reconnects);
    try std.testing.expectEqual(client.session.State.active, sessions[0].state);
}
test "a short TCP receive fails the attempt" {
    // Mirrors short_tcp_receive_fails_the_attempt. A TCP read that completed a strict prefix is a
    // connection-level failure rather than a partial success, and it is refused before any received
    // byte is counted.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 1 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);

    var echoed: [3]u8 = @splat(0xAB);
    var expected: [6]u8 = @splat(0xAB);
    const refused = scheduler.onReceived(&worker.core, 0, &echoed, &expected, started, &steps);
    try std.testing.expectEqual(@as(usize, 1), countSteps(refused, .close));
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.lost);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.received_bytes);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.echoes);
}
test "the reconnect wait begins only after the generation has drained" {
    // Mirrors reconnect_wait_begins_only_after_generation_drained. A failure retires the generation
    // but does not schedule the reconnect: a new socket may not exist while the old one can still
    // produce completions, so the wait starts at the drain and not at the failure.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 1, .reconnect_seconds = 2 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    // The worker derives both from the options at initialisation; the test builds only the records.
    worker.core.reconnect_enabled = true;
    worker.core.reconnect_ticks = worker.clock.millisecondsToTicks(2_000);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);

    const closing = scheduler.onTransportFailure(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(usize, 1), countSteps(closing, .close));
    try std.testing.expectEqual(client.session.State.closing, sessions[0].state);
    // Nothing is scheduled while the generation is still in flight.
    try std.testing.expectEqual(@as(u64, 0), sessions[0].reconnect_at_ticks);

    const drained = started +| worker.clock.millisecondsToTicks(200);
    const after_drain = scheduler.onGenerationDrained(&worker.core, 0, drained, &steps);
    try std.testing.expectEqual(@as(usize, 0), after_drain.len);
    try std.testing.expectEqual(client.session.State.reconnecting, sessions[0].state);
    try std.testing.expectEqual(drained +| worker.core.reconnect_ticks, sessions[0].reconnect_at_ticks);

    // One tick short of the deadline is still a wait; the deadline itself opens the connection.
    _ = scheduler.poll(&worker.core, sessions[0].reconnect_at_ticks -| 1, &steps);
    try std.testing.expectEqual(client.session.State.reconnecting, sessions[0].state);
    const due = scheduler.poll(&worker.core, sessions[0].reconnect_at_ticks, &steps);
    try std.testing.expectEqual(@as(usize, 1), countSteps(due, .connect));
}
test "a send failure after a receive loses the whole unsettled batch" {
    // Mirrors send_failure_after_a_receive_loses_the_whole_unsettled_batch. Accounting waits for both
    // native operations, so a receive that verified is not turned into an echo success by a send that
    // never completed: the whole batch is lost and the failure is counted once.
    var sessions: [1]Session = .{.{}};
    var slots: [1]client.native.transport.Slot = @splat(.{});
    var steps: [3]scheduler.Step = undefined;
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const options = client.types.Options{ .protocol = .tcp, .pipeline_depth = 2, .reconnect_seconds = 0 };
    var worker = buildWorker(&sessions, &slots, &steps, &nodes, &positions, &options, 6);
    const started = worker.clock.nowTicks();
    _ = scheduler.start(&worker.core, started, &steps);
    _ = scheduler.onConnected(&worker.core, 0, started, &steps);

    // The echo verified, but its send is still with the provider, so nothing is accounted yet.
    var buffer: [12]u8 = @splat(0xAB);
    _ = scheduler.onReceived(&worker.core, 0, &buffer, &buffer, started, &steps);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.echoes);

    _ = scheduler.onTransportFailure(&worker.core, 0, started, &steps);
    try std.testing.expectEqual(@as(u64, 0), worker.core.statistics.echoes);
    try std.testing.expectEqual(@as(u64, 2), worker.core.statistics.lost);
    try std.testing.expectEqual(@as(u64, 1), worker.core.statistics.network_errors);
}
