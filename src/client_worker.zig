const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const rio = @import("rio.zig");
const contract = @import("contract.zig");
const pattern_mod = @import("pattern.zig");
const types = @import("types.zig");
const internal = @import("engine_internal.zig");
const timer = @import("timer_heap.zig");
const session_machine = @import("client_session.zig");
const builtin = @import("builtin");

const Worker = internal.Worker;
const Session = internal.Session;
const Metrics = internal.Metrics;
const WorkerResources = internal.WorkerResources;
const allocator = std.heap.page_allocator;
const batch_size: u32 = 256;
const stop_key: usize = 1;

pub const InitError = error{ Frequency, Port, Capacity, Arena, Sessions, TimerNodes, TimerPositions, SocketOwners, TimerHeap, Registration, CompletionQueue };
pub const TestInitStage = enum { port, arena, sessions, timer_nodes, timer_positions, socket_owners, timer_heap, registration, completion_queue };
pub var test_fail_stage: ?TestInitStage = null;

fn injectedFailure(stage: TestInitStage) bool {
    if (!builtin.is_test) return false;
    return test_fail_stage == stage;
}

fn fail(stage: []const u8, native_error: u32) noreturn {
    win32.failFast(stage, native_error);
}

fn resources(worker: *Worker) *WorkerResources {
    return worker.resources.?;
}

const startSocket = session_machine.startSocket;
const connectionFailed = session_machine.connectionFailed;
const processRioResult = session_machine.processRioResult;
const processConnect = session_machine.processConnect;
const processDeadlines = session_machine.processDeadlines;
const stopWorker = session_machine.stopWorker;

pub fn requireNotifySuccess(status: c_int) void {
    if (status != c.ERROR_SUCCESS) fail("RIONotify(client)", @bitCast(status));
}

pub fn requireDequeueCount(count: u32, maximum: u32) u32 {
    if (count == c.RIO_CORRUPT_CQ or count > maximum) fail("RIODequeueCompletion(client)", c.ERROR_INVALID_DATA);
    return count;
}

pub fn requireNotificationDelivered(armed: *bool) void {
    if (!contract.notificationMarkDelivered(armed)) fail("client notification delivery transition", c.ERROR_INVALID_STATE);
}

pub fn requireNotificationRearmed(armed: *bool) void {
    if (!contract.notificationMarkRearmed(armed)) fail("client notification rearm transition", c.ERROR_INVALID_STATE);
}

pub fn requireControlPost(ok: c.BOOL, native_error: u32) void {
    if (ok == c.FALSE) fail("PostQueuedCompletionStatus(client stop)", native_error);
}

fn drain(worker: *Worker) void {
    var results: [batch_size]c.RIORESULT = undefined;
    while (true) {
        const count = requireDequeueCount(worker.rio_api.?.dequeue(worker.completion_queue, &results, batch_size), batch_size);
        if (count == 0) return;
        for (results[0..count]) |result| processRioResult(worker, result);
    }
}

fn arm(worker: *Worker) void {
    if (worker.notification_armed) fail("client notification duplicate arm", c.ERROR_INVALID_STATE);
    worker.notification_overlapped = std.mem.zeroes(c.OVERLAPPED);
    requireNotifySuccess(worker.rio_api.?.notify(worker.completion_queue));
    requireNotificationRearmed(&worker.notification_armed);
}

pub fn completeNotification(worker: *Worker) void {
    requireNotificationDelivered(&worker.notification_armed);
    drain(worker);
    arm(worker);
}

pub fn retireCompletionQueue(worker: *Worker) void {
    if (worker.live_sessions != 0) fail("client CQ retirement with live sessions", c.ERROR_INVALID_STATE);
    if (worker.sessions) |sessions| {
        for (sessions[0..worker.session_count]) |session| {
            if (session.outstanding != 0) fail("client CQ retirement with outstanding operations", c.ERROR_IO_INCOMPLETE);
        }
    }
    const owner = resources(worker);
    if (worker.completion_queue == c.RIO_INVALID_CQ or owner.completion_queue.value != worker.completion_queue)
        fail("client CQ retirement ownership", c.ERROR_INVALID_STATE);
    owner.completion_queue.deinit();
    worker.completion_queue = c.RIO_INVALID_CQ;
    worker.notification_armed = false;
}

fn workerThread(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
    const worker: *Worker = @ptrCast(@alignCast(parameter.?));
    arm(worker);
    for (worker.sessions.?[0..worker.session_count]) |*session| {
        if (!startSocket(session)) connectionFailed(session);
    }
    while (worker.live_sessions != 0) {
        var transferred: c.DWORD = 0;
        var key: usize = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(worker.port, &transferred, &key, &overlapped, worker.timers.?.waitMilliseconds(c.GetTickCount64()));
        const native_error = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS;
        if (overlapped == &worker.notification_overlapped) {
            if (ok == c.FALSE) fail("GetQueuedCompletionStatus(client notification)", native_error);
            if (!internal.notificationPacketMatches(key, overlapped, @intFromPtr(worker), &worker.notification_overlapped)) fail("client RIO notification key", c.ERROR_INVALID_DATA);
            completeNotification(worker);
        } else if (overlapped == null and key == stop_key) {
            stopWorker(worker);
        } else if (overlapped != null and key > stop_key) {
            const first = @intFromPtr(worker.sessions.?);
            const last = first + @sizeOf(Session) * worker.session_count;
            if (key < first or key >= last or (key - first) % @sizeOf(Session) != 0) fail("unexpected ConnectEx completion key", c.ERROR_INVALID_DATA);
            const session: *Session = @ptrFromInt(key);
            if (overlapped != &session.connect_overlapped) fail("unexpected ConnectEx completion identity", c.ERROR_INVALID_DATA);
            processConnect(session, ok != c.FALSE, native_error);
        } else if (ok == c.FALSE and native_error != c.WAIT_TIMEOUT) {
            fail("GetQueuedCompletionStatus(client)", native_error);
        } else if (!(ok == c.FALSE and native_error == c.WAIT_TIMEOUT and overlapped == null)) {
            fail("unexpected client IOCP packet", c.ERROR_INVALID_DATA);
        }
        processDeadlines(worker);
        if (worker.external_stop.?.load(.acquire)) stopWorker(worker);
    }
    retireCompletionQueue(worker);
    return if (worker.fatal.?.load(.acquire)) 1 else 0;
}

pub fn initializeWorker(worker: *Worker, extensions: *const rio.Extensions, options: *const types.Options, remote: *const c.SOCKADDR_IN, pattern: []const u8, maximum_attempt_bytes: usize, metrics: *Metrics, external_stop: *std.atomic.Value(bool), fatal: *std.atomic.Value(bool), worker_index: u32, session_count: u32, memory_share: u64, owner: *WorkerResources) InitError!void {
    worker.* = .{};
    owner.* = .{};
    worker.resources = owner;
    errdefer {
        owner.deinit(allocator);
        worker.* = .{};
    }
    worker.rio_api = &extensions.rio;
    worker.connect_ex = extensions.connect_ex;
    worker.options = options;
    worker.remote_address = remote;
    worker.pattern = pattern;
    worker.maximum_attempt_bytes = maximum_attempt_bytes;
    worker.metrics = metrics;
    worker.external_stop = external_stop;
    worker.fatal = fatal;
    worker.worker_index = worker_index;
    worker.session_count = session_count;
    worker.live_sessions = session_count;
    if (c.QueryPerformanceFrequency(&worker.performance_frequency) == c.FALSE or worker.performance_frequency.QuadPart <= 0) {
        win32.report("QueryPerformanceFrequency", c.GetLastError());
        return error.Frequency;
    }
    worker.port = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1);
    owner.port.reset(worker.port);
    if (worker.port == null) {
        win32.report("CreateIoCompletionPort(client worker)", c.GetLastError());
        return error.Port;
    }
    if (injectedFailure(.port)) return error.Port;
    const arena_bytes = contract.checkedStorageBytes(session_count, maximum_attempt_bytes, memory_share) orelse {
        win32.report("client worker IOCP/CQ/arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Capacity;
    };
    if (options.cq_capacity < session_count * 2 or arena_bytes > std.math.maxInt(u32)) {
        win32.report("client worker IOCP/CQ/arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Capacity;
    }
    owner.arena = win32.VirtualMemory.alloc(arena_bytes) catch {
        win32.report("VirtualAlloc(client worker)", c.GetLastError());
        return error.Arena;
    };
    worker.memory = owner.arena.bytes();
    if (injectedFailure(.arena)) return error.Arena;
    owner.sessions = allocator.alloc(Session, session_count) catch {
        win32.report("client worker sessions allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Sessions;
    };
    if (injectedFailure(.sessions)) return error.Sessions;
    owner.timer_nodes = allocator.alloc(timer.Node, session_count) catch {
        win32.report("client worker timer nodes allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.TimerNodes;
    };
    if (injectedFailure(.timer_nodes)) return error.TimerNodes;
    owner.timer_positions = allocator.alloc(u32, session_count) catch {
        win32.report("client worker timer positions allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.TimerPositions;
    };
    if (injectedFailure(.timer_positions)) return error.TimerPositions;
    owner.session_sockets = allocator.alloc(win32.Socket, session_count) catch {
        win32.report("client worker socket owners allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.SocketOwners;
    };
    @memset(owner.sessions, .{});
    @memset(owner.session_sockets, .{});
    if (injectedFailure(.socket_owners)) return error.SocketOwners;
    worker.sessions = owner.sessions.ptr;
    worker.timer_nodes = owner.timer_nodes.ptr;
    worker.timer_positions = owner.timer_positions.ptr;
    worker.timers = timer.Heap.init(owner.timer_nodes, owner.timer_positions) catch {
        win32.report("client worker timer heap", c.ERROR_INVALID_DATA);
        return error.TimerHeap;
    };
    if (injectedFailure(.timer_heap)) return error.TimerHeap;
    worker.registration = extensions.rio.registerBuffer(worker.memory.?, @intCast(arena_bytes));
    owner.registration.reset(&extensions.rio, worker.registration);
    if (worker.registration == c.RIO_INVALID_BUFFERID) {
        win32.report("RIORegisterBuffer(client)", @intCast(c.WSAGetLastError()));
        return error.Registration;
    }
    if (injectedFailure(.registration)) return error.Registration;
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = worker.port;
    notification.Iocp.CompletionKey = @ptrCast(worker);
    notification.Iocp.Overlapped = @ptrCast(&worker.notification_overlapped);
    worker.completion_queue = extensions.rio.createCq(options.cq_capacity, &notification);
    owner.completion_queue.reset(&extensions.rio, worker.completion_queue);
    if (worker.completion_queue == c.RIO_INVALID_CQ) {
        win32.report("RIOCreateCompletionQueue(client)", @intCast(c.WSAGetLastError()));
        return error.CompletionQueue;
    }
    if (injectedFailure(.completion_queue)) return error.CompletionQueue;
    for (owner.sessions, 0..) |*session, index| {
        session.owner = worker;
        session.index = @intCast(index);
        session.receive_request = .{ .session = session, .operation = .receive };
        session.send_request = .{ .session = session, .operation = .send };
        session.receive_buffer.BufferId = worker.registration;
        session.send_buffer.BufferId = worker.registration;
        const start = index * 2 * maximum_attempt_bytes;
        pattern_mod.fillRepeated(worker.memory.?[start .. start + maximum_attempt_bytes], pattern);
    }
    worker.ready = true;
}

pub fn startWorker(worker: *Worker) bool {
    worker.thread = c.CreateThread(null, 0, workerThread, @ptrCast(worker), 0, null);
    resources(worker).thread.reset(worker.thread);
    if (worker.thread == null) {
        win32.report("CreateThread(client worker)", c.GetLastError());
        return false;
    }
    return true;
}

pub fn postWorkerStop(worker: *Worker) void {
    const ok = c.PostQueuedCompletionStatus(worker.port, 0, stop_key, null);
    requireControlPost(ok, if (ok == c.FALSE) c.GetLastError() else 0);
}

pub fn joinWorker(worker: *Worker) void {
    if (worker.thread != null and c.WaitForSingleObject(worker.thread, c.INFINITE) != c.WAIT_OBJECT_0) fail("WaitForSingleObject(client worker)", c.GetLastError());
}

pub fn destroyWorker(worker: *Worker) void {
    const owner = resources(worker);
    const had_thread = worker.thread != null;
    joinWorker(worker);
    owner.thread.deinit();
    worker.thread = null;
    if (had_thread) {
        var outstanding: u32 = 0;
        for (owner.sessions) |session| outstanding += session.outstanding;
        const lifecycle: internal.WorkerLifecycle = .{ .phase = .stopped, .live_sessions = worker.live_sessions, .total_outstanding = outstanding, .notification_armed = worker.notification_armed };
        if (!internal.workerMayRelease(&lifecycle) or worker.timers.?.len != 0) fail("client worker release precondition", c.ERROR_INVALID_STATE);
    }
    owner.deinit(allocator);
    worker.resources = null;
    worker.ready = false;
}
