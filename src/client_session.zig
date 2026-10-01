const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const internal = @import("engine_internal.zig");
const contract = @import("contract.zig");
const bench_config = @import("bench_config");
const Session = internal.Session;
const Worker = internal.Worker;

fn fail(stage: []const u8, native_error: u32) noreturn {
    win32.failFast(stage, native_error);
}

fn resources(worker: *Worker) *internal.WorkerResources {
    return worker.resources.?;
}

fn closeSocket(session: *Session) void {
    resources(session.owner.?).session_sockets[session.index].deinit();
    session.socket = c.INVALID_SOCKET;
}

fn schedule(session: *Session, deadline: u64) void {
    if (!session.owner.?.timers.?.insertOrUpdate(session.index, deadline)) fail("client timer insert/update", c.ERROR_INVALID_DATA);
}

fn unschedule(session: *Session) void {
    _ = session.owner.?.timers.?.remove(session.index);
}

fn markDone(session: *Session) void {
    unschedule(session);
    closeSocket(session);
    session.request_queue = c.RIO_INVALID_RQ;
    if (session.state != .done) {
        session.state = .done;
        session.owner.?.live_sessions -= 1;
    }
}

fn finishClose(session: *Session) void {
    const worker = session.owner.?;
    if (session.reconnect_after_close and !worker.stopping) {
        session.state = .reconnecting;
        session.next_action = c.GetTickCount64() + @as(u64, @intCast(worker.options.?.reconnect_seconds)) * 1000;
        schedule(session, session.next_action);
    } else markDone(session);
}

pub fn createRequestQueue(session: *Session) bool {
    const worker = session.owner.?;
    session.request_queue = worker.rio_api.?.createRq(session.socket, 1, 1, 1, 1, worker.completion_queue, worker.completion_queue, @ptrCast(session));
    if (session.request_queue == c.RIO_INVALID_RQ) {
        win32.report("RIOCreateRequestQueue(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
    return true;
}

pub fn closeAttempt(session: *Session, reconnect: bool) void {
    if (session.state == .closing or session.state == .done) return;
    unschedule(session);
    session.reconnect_after_close = reconnect;
    session.state = .closing;
    closeSocket(session);
    if (session.outstanding == 0) finishClose(session);
}

pub fn postSend(session: *Session) bool {
    const worker = session.owner.?;
    session.send_request.operation = .send;
    session.send_buffer.Offset = @intCast(@as(usize, session.index) * 2 * worker.maximum_attempt_bytes + session.send_offset);
    session.send_buffer.Length = @intCast(session.attempt_bytes - session.send_offset);
    if (!worker.rio_api.?.send(session.request_queue, &session.send_buffer, 0, @ptrCast(&session.send_request))) {
        win32.report("RIOSend(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
    session.outstanding += 1;
    return true;
}

pub fn postReceive(session: *Session) bool {
    const worker = session.owner.?;
    session.receive_request.operation = .receive;
    session.receive_buffer.Offset = @intCast(@as(usize, session.index) * 2 * worker.maximum_attempt_bytes + worker.maximum_attempt_bytes);
    session.receive_buffer.Length = @intCast(session.attempt_bytes);
    const flags: u32 = if (worker.options.?.protocol == .tcp) c.RIO_MSG_WAITALL else 0;
    if (!worker.rio_api.?.receive(session.request_queue, &session.receive_buffer, flags, @ptrCast(&session.receive_request))) {
        win32.report("RIOReceive(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
    session.outstanding += 1;
    return true;
}

pub fn beginAttempt(session: *Session) bool {
    const worker = session.owner.?;
    const requested: u64 = if (worker.options.?.protocol == .tcp) worker.options.?.pipeline_depth else 1;
    const granted = contract.claimAttempts(&worker.metrics.?.claimed, worker.options.?.echo_count, requested);
    if (granted == 0) {
        markDone(session);
        return true;
    }
    session.requested_echoes = granted;
    session.attempt_bytes = worker.pattern.len * @as(usize, @intCast(granted));
    session.send_offset = 0;
    session.received_bytes = 0;
    session.send_done = false;
    session.receive_done = false;
    session.attempt_accounted = false;
    session.state = .active;
    if (c.QueryPerformanceCounter(&session.started_at) == c.FALSE) fail("QueryPerformanceCounter(client)", c.GetLastError());
    session.deadline = c.GetTickCount64() + @as(u64, worker.options.?.timeout_seconds) * 1000;
    schedule(session, session.deadline);
    if (!postReceive(session)) return false;
    if (!postSend(session)) return false;
    return true;
}

pub fn postUdpAttempt(session: *Session) bool {
    return beginAttempt(session);
}

pub fn startSocket(session: *Session) bool {
    const worker = session.owner.?;
    const tcp = worker.options.?.protocol == .tcp;
    session.socket = win32.registeredSocket(if (tcp) c.SOCK_STREAM else c.SOCK_DGRAM, if (tcp) c.IPPROTO_TCP else c.IPPROTO_UDP);
    resources(worker).session_sockets[session.index].reset(session.socket);
    if (session.socket == c.INVALID_SOCKET or !win32.configureSocket(session.socket, worker.options.?.socket_buffer_bytes, tcp)) {
        win32.report("client socket creation", @intCast(c.WSAGetLastError()));
        return false;
    }
    var local: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    local.sin_family = c.AF_INET;
    local.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
    local.sin_port = c.htons(worker.options.?.local_port);
    if (c.bind(session.socket, @ptrCast(&local), @sizeOf(c.SOCKADDR_IN)) != 0) {
        win32.report("bind(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
    if (!tcp) {
        if (c.connect(session.socket, @ptrCast(worker.remote_address.?), @sizeOf(c.SOCKADDR_IN)) != 0 or !createRequestQueue(session)) {
            win32.report("connect/RQ(UDP client)", @intCast(c.WSAGetLastError()));
            return false;
        }
        return beginAttempt(session);
    }
    const socket_handle: c.HANDLE = @ptrFromInt(session.socket);
    if (c.CreateIoCompletionPort(socket_handle, worker.port, @intFromPtr(session), 0) != worker.port) {
        win32.report("CreateIoCompletionPort(ConnectEx socket)", c.GetLastError());
        return false;
    }
    session.connect_overlapped = std.mem.zeroes(c.OVERLAPPED);
    session.state = .connecting;
    session.deadline = c.GetTickCount64() + @as(u64, worker.options.?.timeout_seconds) * 1000;
    schedule(session, session.deadline);
    session.outstanding += 1;
    const connected = worker.connect_ex.?(session.socket, @ptrCast(worker.remote_address.?), @sizeOf(c.SOCKADDR_IN), null, 0, null, &session.connect_overlapped);
    if (connected == c.FALSE and c.WSAGetLastError() != c.ERROR_IO_PENDING) {
        session.outstanding -= 1;
        win32.report("ConnectEx", @intCast(c.WSAGetLastError()));
        return false;
    }
    return true;
}

pub fn startUdpSession(session: *Session) bool {
    return startSocket(session);
}

pub fn connectionFailed(session: *Session) void {
    const worker = session.owner.?;
    if (session.state == .active and !session.attempt_accounted) {
        _ = worker.metrics.?.lost.fetchAdd(session.requested_echoes, .monotonic);
        session.attempt_accounted = true;
    }
    _ = worker.metrics.?.network_errors.fetchAdd(1, .monotonic);
    closeAttempt(session, worker.options.?.reconnect_seconds >= 0 and !worker.stopping);
}

fn recordLatency(worker: *Worker, started: c.LARGE_INTEGER) void {
    var finish: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceCounter(&finish) == c.FALSE) fail("QueryPerformanceCounter(client)", c.GetLastError());
    const ticks: u64 = @intCast(@max(@as(i64, 0), finish.QuadPart - started.QuadPart));
    const microseconds: u64 = @intCast(@max(@as(u128, 1), @as(u128, ticks) * 1_000_000 / @as(u64, @intCast(worker.performance_frequency.QuadPart))));
    const bin: usize = @min(@as(usize, 63), @as(usize, std.math.log2_int(u64, microseconds)));
    _ = worker.metrics.?.latency_bins[bin].fetchAdd(1, .monotonic);
    if (bench_config.enabled) worker.bench_histogram.record(microseconds);
}

fn completeAttempt(session: *Session) void {
    if (!session.send_done or !session.receive_done or session.outstanding != 0) return;
    const worker = session.owner.?;
    const start = @as(usize, session.index) * 2 * worker.maximum_attempt_bytes;
    const sent = worker.memory.?[start .. start + session.attempt_bytes];
    const received = worker.memory.?[start + worker.maximum_attempt_bytes .. start + worker.maximum_attempt_bytes + session.attempt_bytes];
    const equal = session.received_bytes == session.attempt_bytes and std.mem.eql(u8, sent, received);
    recordLatency(worker, session.started_at);
    if (equal) {
        _ = worker.metrics.?.echoed.fetchAdd(session.requested_echoes, .monotonic);
        _ = worker.metrics.?.bytes.fetchAdd(session.attempt_bytes, .monotonic);
    } else _ = worker.metrics.?.corrupted.fetchAdd(session.requested_echoes, .monotonic);
    session.attempt_accounted = true;
    if (worker.options.?.interval_milliseconds != 0) {
        session.state = .pacing;
        session.next_action = c.GetTickCount64() + worker.options.?.interval_milliseconds;
        schedule(session, session.next_action);
    } else if (!beginAttempt(session)) connectionFailed(session);
}

pub fn processRioResult(worker: *Worker, result: c.RIORESULT) void {
    const context = result.RequestContext orelse fail("client RIO RequestContext", c.ERROR_INVALID_DATA);
    const request: *internal.Request = @ptrFromInt(@intFromPtr(context));
    if (!internal.requestContextValid(request, worker.sessions.?[0..worker.session_count], worker)) fail("client RIO RequestContext", c.ERROR_INVALID_DATA);
    const session = request.session.?;
    if (session.outstanding == 0) fail("client RIO outstanding count", c.ERROR_INVALID_DATA);
    session.outstanding -= 1;
    if (session.state == .closing) {
        if (session.outstanding == 0) finishClose(session);
        return;
    }
    if (result.Status != c.ERROR_SUCCESS) {
        if (!session.attempt_accounted) {
            _ = worker.metrics.?.lost.fetchAdd(session.requested_echoes, .monotonic);
            session.attempt_accounted = true;
        }
        connectionFailed(session);
        return;
    }
    if (request.operation == .send) {
        if (result.BytesTransferred == 0 or result.BytesTransferred > session.attempt_bytes - session.send_offset) {
            connectionFailed(session);
            return;
        }
        session.send_offset += result.BytesTransferred;
        if (session.send_offset < session.attempt_bytes) {
            if (!postSend(session)) connectionFailed(session);
            return;
        }
        session.send_done = true;
    } else {
        if (worker.options.?.protocol == .tcp and result.BytesTransferred != session.attempt_bytes) {
            connectionFailed(session);
            return;
        }
        session.received_bytes = result.BytesTransferred;
        session.receive_done = true;
    }
    completeAttempt(session);
}

pub fn processConnect(session: *Session, completion_ok: bool, native_error: u32) void {
    if (session.outstanding == 0) fail("ConnectEx outstanding count", c.ERROR_INVALID_DATA);
    session.outstanding -= 1;
    if (session.state == .closing) {
        if (session.outstanding == 0) finishClose(session);
        return;
    }
    if (!completion_ok or c.setsockopt(session.socket, c.SOL_SOCKET, c.SO_UPDATE_CONNECT_CONTEXT, null, 0) != 0) {
        win32.report("ConnectEx completion", if (!completion_ok) native_error else @intCast(c.WSAGetLastError()));
        connectionFailed(session);
        return;
    }
    if (!createRequestQueue(session) or !beginAttempt(session)) connectionFailed(session);
}

pub fn processDeadlines(worker: *Worker) void {
    const now = c.GetTickCount64();
    while (worker.timers.?.popExpired(now)) |index| {
        const session = &worker.sessions.?[index];
        switch (session.state) {
            .active, .connecting => connectionFailed(session),
            .pacing => if (!beginAttempt(session)) connectionFailed(session),
            .reconnecting => {
                session.request_queue = c.RIO_INVALID_RQ;
                if (!startSocket(session)) connectionFailed(session);
            },
            else => {},
        }
    }
}

pub fn stopWorker(worker: *Worker) void {
    if (worker.stopping) return;
    worker.stopping = true;
    for (worker.sessions.?[0..worker.session_count]) |*session| {
        if (session.state == .done) continue;
        if (worker.fatal.?.load(.acquire) and session.state == .active and !session.attempt_accounted) {
            _ = worker.metrics.?.lost.fetchAdd(session.requested_echoes, .monotonic);
            session.attempt_accounted = true;
        }
        session.reconnect_after_close = false;
        unschedule(session);
        if (session.outstanding == 0) markDone(session) else {
            session.state = .closing;
            closeSocket(session);
        }
    }
}
