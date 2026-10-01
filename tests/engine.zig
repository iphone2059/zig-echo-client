const std = @import("std");
const client = @import("client");
const win32 = client.win32;
const rio = client.rio;
const c = win32.c;
const internal = client.engine_internal;
const timer = client.timer_heap;
const engine = client.engine;
const session_machine = client.client_session;

var last_reposted_offset: u32 = 0;
var last_reposted_length: u32 = 0;
fn fakeSend(_: c.RIO_RQ, buffers: [*c]c.RIO_BUF, count: c.ULONG, _: c.DWORD, _: ?*anyopaque) callconv(.winapi) c.BOOL {
    if (count != 1) return c.FALSE;
    last_reposted_offset = buffers[0].Offset;
    last_reposted_length = buffers[0].Length;
    return c.TRUE;
}

test "client partial RIOSend completion reposts only the unsent tail" {
    var api: rio.Api = .{ .table = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE) };
    api.table.RIOSend = fakeSend;
    var worker: internal.Worker = .{};
    var sessions: [1]internal.Session = .{.{}};
    worker.rio_api = &api;
    worker.sessions = &sessions;
    worker.session_count = 1;
    worker.maximum_attempt_bytes = 100;
    sessions[0].owner = &worker;
    sessions[0].state = .active;
    sessions[0].attempt_bytes = 100;
    sessions[0].outstanding = 2;
    sessions[0].send_request.session = &sessions[0];
    sessions[0].send_request.operation = .send;
    session_machine.processRioResult(&worker, .{
        .Status = c.ERROR_SUCCESS,
        .BytesTransferred = 40,
        .SocketContext = null,
        .RequestContext = @ptrCast(&sessions[0].send_request),
    });
    try std.testing.expectEqual(@as(usize, 40), sessions[0].send_offset);
    try std.testing.expectEqual(@as(u32, 40), last_reposted_offset);
    try std.testing.expectEqual(@as(u32, 60), last_reposted_length);
    try std.testing.expectEqual(@as(u32, 2), sessions[0].outstanding);
}

test "client 17 logical echoes at pipeline 8 claim batches of 8 8 and 1" {
    var claimed = std.atomic.Value(u64).init(0);
    const first = client.contract.claimAttempts(&claimed, 17, 8);
    const second = client.contract.claimAttempts(&claimed, 17, 8);
    const third = client.contract.claimAttempts(&claimed, 17, 8);
    try std.testing.expectEqual(@as(u64, 8), first);
    try std.testing.expectEqual(@as(u64, 8), second);
    try std.testing.expectEqual(@as(u64, 1), third);
    try std.testing.expectEqual(@as(u64, 0), client.contract.claimAttempts(&claimed, 17, 8));
    try std.testing.expectEqual(@as(u64, 17 * 4096), (first + second + third) * 4096);
}

test "client close waits for both posted send and receive completions" {
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const heap = try timer.Heap.init(&nodes, &positions);
    var sockets: [1]win32.Socket = .{.{}};
    var owner: internal.WorkerResources = .{ .session_sockets = &sockets };
    var worker: internal.Worker = .{};
    var sessions: [1]internal.Session = .{.{}};
    worker.resources = &owner;
    worker.sessions = &sessions;
    worker.session_count = 1;
    worker.live_sessions = 1;
    worker.timers = heap;
    sessions[0].owner = &worker;
    sessions[0].state = .active;
    sessions[0].outstanding = 2;
    sessions[0].send_request.session = &sessions[0];
    sessions[0].receive_request.session = &sessions[0];
    session_machine.closeAttempt(&sessions[0], false);
    try std.testing.expectEqual(internal.SessionState.closing, sessions[0].state);
    try std.testing.expectEqual(@as(u32, 2), sessions[0].outstanding);
    const requests = [_]*internal.Request{ &sessions[0].send_request, &sessions[0].receive_request };
    for (requests, 0..) |request, index| {
        session_machine.processRioResult(&worker, .{
            .Status = c.ERROR_SUCCESS,
            .BytesTransferred = 0,
            .SocketContext = null,
            .RequestContext = @ptrCast(request),
        });
        try std.testing.expectEqual(if (index == 0) internal.SessionState.closing else .done, sessions[0].state);
    }
    try std.testing.expectEqual(@as(u32, 0), worker.live_sessions);
}

test "client failed active attempt accounts claimed echoes once" {
    var nodes: [1]timer.Node = undefined;
    var positions: [1]u32 = undefined;
    const heap = try timer.Heap.init(&nodes, &positions);
    var sockets: [1]win32.Socket = .{.{}};
    var owner: internal.WorkerResources = .{ .session_sockets = &sockets };
    var metrics: internal.Metrics = .{};
    metrics.claimed.store(8, .monotonic);
    const options: client.types.Options = .{};
    var worker: internal.Worker = .{};
    var sessions: [1]internal.Session = .{.{}};
    worker.resources = &owner;
    worker.sessions = &sessions;
    worker.session_count = 1;
    worker.live_sessions = 1;
    worker.timers = heap;
    worker.options = &options;
    worker.metrics = &metrics;
    sessions[0].owner = &worker;
    sessions[0].state = .active;
    sessions[0].outstanding = 1;
    sessions[0].requested_echoes = 8;
    sessions[0].send_request.session = &sessions[0];
    session_machine.connectionFailed(&sessions[0]);
    try std.testing.expectEqual(internal.SessionState.closing, sessions[0].state);
    try std.testing.expectEqual(@as(u64, 8), metrics.lost.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.network_errors.load(.monotonic));
    try std.testing.expect(sessions[0].attempt_accounted);
    session_machine.processRioResult(&worker, .{
        .Status = c.ERROR_SUCCESS,
        .BytesTransferred = 0,
        .SocketContext = null,
        .RequestContext = @ptrCast(&sessions[0].send_request),
    });
    try std.testing.expectEqual(internal.SessionState.done, sessions[0].state);
    try std.testing.expectEqual(@as(u64, 8), metrics.lost.load(.monotonic));
    try std.testing.expect(internal.sessionTerminalAccountingValid(8, 0, 0, metrics.lost.load(.monotonic)));
}

comptime {
    if (@FieldType(internal.Worker, "resources") != ?*internal.WorkerResources)
        @compileError("client worker resources must have a concrete owner type");
    if (engine.WorkerResources != internal.WorkerResources)
        @compileError("client engine compatibility alias must retain the concrete owner type");
}

test "client unpublished partly initialized owner releases acquired resources" {
    var owner: internal.WorkerResources = .{};
    owner.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    try std.testing.expect(owner.port.get() != null);
    owner.arena = try win32.VirtualMemory.alloc(4096);
    var worker: internal.Worker = .{};
    worker.resources = &owner;
    engine.destroyWorker(&worker);
    try std.testing.expect(owner.port.get() == null);
    try std.testing.expect(owner.arena.ptr == null);
    try std.testing.expect(worker.resources == null);
}

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
    worker.resources = &owner;
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
