const std = @import("std");
const client = @import("client");
const win32 = client.win32;
const rio = client.rio;
const c = win32.c;
const internal = client.engine_internal;
const timer = client.timer_heap;
const engine = client.engine;

test "client worker partition covers every session without empty workers" {
    try std.testing.expectEqual(@as(u32, 2), engine.workerCount(2, 8));
    try std.testing.expectEqual(@as(u32, 3), engine.partitionSessions(10, 3, 0));
    try std.testing.expectEqual(@as(u32, 3), engine.partitionSessions(10, 3, 1));
    try std.testing.expectEqual(@as(u32, 4), engine.partitionSessions(10, 3, 2));
}

test "client Win32 owners transfer reset and destroy exactly once" {
    var socket: win32.Socket = .{};
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.get());
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.take());
    socket.reset(c.INVALID_SOCKET);
    socket.deinit();
    var handle: win32.Handle = .{};
    try std.testing.expect(handle.get() == null);
    handle.reset(null);
    handle.deinit();
    var memory = try win32.VirtualMemory.alloc(4096);
    const pointer = memory.take();
    memory.reset(pointer);
    memory.deinit();
    memory.deinit();
}

test "client registered sockets require overlapped RIO and ABI is exact" {
    try std.testing.expectEqual(c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO, win32.registeredSocketFlags());
    try std.testing.expectEqual(@as(u32, 0x00000004), c.RIO_MSG_WAITALL);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.RIO_BUF));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.RIORESULT));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.OVERLAPPED));
}

test "client loads complete RIO table and ConnectEx" {
    var empty: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
    try std.testing.expect(!rio.Api.tableComplete(&empty));
    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const extensions = try rio.Extensions.load();
    try std.testing.expect(rio.Api.tableComplete(&extensions.rio.table));
    try std.testing.expect(extensions.connect_ex != null);
}

test "client timer uses exact deadline and saturated DWORD wait" {
    var nodes: [3]timer.Node = undefined;
    var positions: [3]u32 = undefined;
    var heap = try timer.Heap.init(&nodes, &positions);
    try std.testing.expectEqual(c.INFINITE, heap.waitMilliseconds(5));
    try std.testing.expect(heap.insertOrUpdate(2, 30));
    try std.testing.expect(heap.insertOrUpdate(1, 30));
    try std.testing.expectEqual(@as(u32, 25), heap.waitMilliseconds(5));
    try std.testing.expectEqual(@as(?u32, 1), heap.popExpired(30));
    try std.testing.expectEqual(@as(?u32, 2), heap.popExpired(30));
    try std.testing.expect(heap.insertOrUpdate(0, std.math.maxInt(u64)));
    try std.testing.expectEqual(c.INFINITE - 1, heap.waitMilliseconds(0));
}

test "client release barrier and terminal accounting require all completions" {
    var state: internal.WorkerLifecycle = .{ .phase = .draining, .live_sessions = 0, .total_outstanding = 0, .notification_armed = false };
    try std.testing.expect(!internal.workerMayRelease(&state));
    state.phase = .stopped;
    try std.testing.expect(internal.workerMayRelease(&state));
    state.total_outstanding = 1;
    try std.testing.expect(!internal.workerMayRelease(&state));
    try std.testing.expect(internal.sessionTerminalAccountingValid(10, 8, 1, 1));
    try std.testing.expect(!internal.sessionTerminalAccountingValid(10, 8, 1, 0));
}

test "client stable context and IOCP notification identities are exact" {
    var worker: internal.Worker = .{};
    var sessions: [2]internal.Session = .{ .{ .index = 0 }, .{ .index = 1 } };
    sessions[0].owner = &worker;
    sessions[0].receive_request.session = &sessions[0];
    sessions[0].send_request.session = &sessions[0];
    try std.testing.expect(internal.requestContextValid(&sessions[0].receive_request, &sessions, &worker));
    try std.testing.expect(internal.requestContextValid(&sessions[0].send_request, &sessions, &worker));
    var foreign: internal.Session = .{};
    foreign.owner = &worker;
    foreign.receive_request.session = &foreign;
    try std.testing.expect(!internal.requestContextValid(&foreign.receive_request, &sessions, &worker));
    var expected: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    var other: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    try std.testing.expect(internal.notificationPacketMatches(7, &expected, 7, &expected));
    try std.testing.expect(!internal.notificationPacketMatches(7, &other, 7, &expected));
}

test "client closes idle CQ with an armed and already queued notification" {
    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const api = try rio.Api.load();
    var owner: engine.WorkerResources = .{};
    defer owner.completion_queue.deinit();
    defer owner.port.deinit();
    owner.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    try std.testing.expect(owner.port.value != null);
    var worker: internal.Worker = .{};
    worker.resources = @ptrCast(&owner);
    worker.port = owner.port.value;
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = worker.port;
    notification.Iocp.CompletionKey = @ptrCast(&worker);
    notification.Iocp.Overlapped = @ptrCast(&worker.notification_overlapped);
    const cq = api.createCq(8, &notification);
    try std.testing.expect(cq != c.RIO_INVALID_CQ);
    owner.completion_queue.reset(&api, cq);
    worker.completion_queue = cq;
    try std.testing.expectEqual(@as(c_int, c.ERROR_SUCCESS), api.notify(cq));
    worker.notification_armed = true;
    try std.testing.expect(c.PostQueuedCompletionStatus(worker.port, 0, @intFromPtr(&worker), &worker.notification_overlapped) != c.FALSE);

    engine.retireCompletionQueue(&worker);

    try std.testing.expectEqual(c.RIO_INVALID_CQ, worker.completion_queue);
    try std.testing.expectEqual(c.RIO_INVALID_CQ, owner.completion_queue.value);
    try std.testing.expect(!worker.notification_armed);
    var transferred: c.DWORD = 0;
    var key: usize = 0;
    var overlapped: [*c]c.OVERLAPPED = null;
    try std.testing.expect(c.GetQueuedCompletionStatus(worker.port, &transferred, &key, &overlapped, 0) != c.FALSE);
    try std.testing.expectEqual(@intFromPtr(&worker), key);
    try std.testing.expect(overlapped == &worker.notification_overlapped);
}

test "client atomic metrics count beyond 32 bits and percentile boundaries" {
    var metrics: internal.Metrics = .{};
    metrics.echoed.store(@as(u64, 1) << 40, .monotonic);
    _ = metrics.echoed.fetchAdd(1, .monotonic);
    try std.testing.expectEqual((@as(u64, 1) << 40) + 1, metrics.echoed.load(.monotonic));
    metrics.latency_bins[10].store(4, .monotonic);
    metrics.latency_bins[12].store(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 1024), internal.percentile(&metrics, 5, 50, 100));
    try std.testing.expectEqual(@as(u64, 4096), internal.percentile(&metrics, 5, 99, 100));
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
