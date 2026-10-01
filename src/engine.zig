const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const rio = @import("rio.zig");
const contract = @import("contract.zig");
const pattern_mod = @import("pattern.zig");
const types = @import("types.zig");
const internal = @import("engine_internal.zig");
const timer = @import("timer_heap.zig");
const bench_config = @import("bench_config");
const session_machine = @import("client_session.zig");

pub const Worker = internal.Worker;
pub const Session = internal.Session;
pub const Metrics = internal.Metrics;
const batch_size: u32 = 256;
const stop_key: usize = 1;
const allocator = std.heap.page_allocator;

pub const WorkerResources = internal.WorkerResources;

fn resources(worker: *Worker) *WorkerResources {
    return worker.resources.?;
}

pub fn workerCount(sessions: u32, requested: u32) u32 {
    const automatic = @max(@as(u32, 1), @min(@as(u32, 32), c.GetActiveProcessorCount(c.ALL_PROCESSOR_GROUPS)));
    return @min(sessions, if (requested == 0) automatic else requested);
}

pub fn partitionSessions(total: u32, workers: u32, index: u32) u32 {
    const base = total / workers;
    const remainder = total % workers;
    return base + @intFromBool(index >= workers - remainder);
}

fn fail(stage: []const u8, error_code: u32) noreturn {
    win32.failFast(stage, error_code);
}

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

pub const createRequestQueue = session_machine.createRequestQueue;
pub const closeAttempt = session_machine.closeAttempt;
pub const postSend = session_machine.postSend;
pub const postReceive = session_machine.postReceive;
pub const beginAttempt = session_machine.beginAttempt;
pub const postUdpAttempt = session_machine.postUdpAttempt;
pub const startSocket = session_machine.startSocket;
pub const startUdpSession = session_machine.startUdpSession;
pub const processRioResult = session_machine.processRioResult;
pub const processConnect = session_machine.processConnect;
pub const processDeadlines = session_machine.processDeadlines;
const connectionFailed = session_machine.connectionFailed;
const stopWorker = session_machine.stopWorker;

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
            requireNotificationDelivered(&worker.notification_armed);
            drain(worker);
            arm(worker);
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

pub fn initializeWorker(worker: *Worker, extensions: *const rio.Extensions, options: *const types.Options, remote: *const c.SOCKADDR_IN, pattern: []const u8, maximum_attempt_bytes: usize, metrics: *Metrics, external_stop: *std.atomic.Value(bool), fatal: *std.atomic.Value(bool), worker_index: u32, session_count: u32, memory_share: u64, owner: *WorkerResources) bool {
    worker.* = .{};
    owner.* = .{};
    worker.resources = owner;
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
        return false;
    }
    worker.port = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1);
    owner.port.reset(worker.port);
    const arena_bytes = contract.checkedStorageBytes(session_count, maximum_attempt_bytes, memory_share) orelse {
        win32.report("client worker IOCP/CQ/arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return false;
    };
    if (worker.port == null or options.cq_capacity < session_count * 2 or arena_bytes > std.math.maxInt(u32)) {
        win32.report("client worker IOCP/CQ/arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return false;
    }
    owner.arena = win32.VirtualMemory.alloc(arena_bytes) catch return false;
    worker.memory = owner.arena.bytes();
    owner.sessions = allocator.alloc(Session, session_count) catch return false;
    owner.timer_nodes = allocator.alloc(timer.Node, session_count) catch return false;
    owner.timer_positions = allocator.alloc(u32, session_count) catch return false;
    owner.session_sockets = allocator.alloc(win32.Socket, session_count) catch return false;
    @memset(owner.sessions, .{});
    @memset(owner.session_sockets, .{});
    worker.sessions = owner.sessions.ptr;
    worker.timer_nodes = owner.timer_nodes.ptr;
    worker.timer_positions = owner.timer_positions.ptr;
    worker.timers = timer.Heap.init(owner.timer_nodes, owner.timer_positions) catch return false;
    worker.registration = extensions.rio.registerBuffer(worker.memory.?, @intCast(arena_bytes));
    owner.registration.reset(&extensions.rio, worker.registration);
    if (worker.registration == c.RIO_INVALID_BUFFERID) {
        win32.report("RIORegisterBuffer(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = worker.port;
    notification.Iocp.CompletionKey = @ptrCast(worker);
    notification.Iocp.Overlapped = @ptrCast(&worker.notification_overlapped);
    worker.completion_queue = extensions.rio.createCq(options.cq_capacity, &notification);
    owner.completion_queue.reset(&extensions.rio, worker.completion_queue);
    if (worker.completion_queue == c.RIO_INVALID_CQ) {
        win32.report("RIOCreateCompletionQueue(client)", @intCast(c.WSAGetLastError()));
        return false;
    }
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
    return true;
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

fn resolveIpv4(options: *const types.Options, remote: *c.SOCKADDR_IN) bool {
    var service: [16]u16 = @splat(0);
    var ascii: [16]u8 = undefined;
    const digits = std.fmt.bufPrint(&ascii, "{d}", .{options.remote_port}) catch return false;
    for (digits, 0..) |ch, index| service[index] = ch;
    var hints: c.ADDRINFOW = std.mem.zeroes(c.ADDRINFOW);
    hints.ai_family = c.AF_INET;
    var results: [*c]c.ADDRINFOW = null;
    const status = c.GetAddrInfoW(@ptrCast(&options.host), @ptrCast(&service), &hints, &results);
    if (status != 0 or results == null) {
        win32.report("GetAddrInfoW(IPv4)", @intCast(status));
        return false;
    }
    defer c.FreeAddrInfoW(results);
    remote.* = (@as(*const c.SOCKADDR_IN, @ptrCast(@alignCast(results.*.ai_addr)))).*;
    return true;
}

pub fn buildPattern(options: *const types.Options) ?[]u8 {
    if (options.pattern_kind == .binary_counter or options.pattern_kind == .printable_counter) {
        const output = allocator.alloc(u8, options.pattern_bytes) catch return null;
        if (options.pattern_kind == .binary_counter) pattern_mod.fillBinary(output) else pattern_mod.fillPrintable(output);
        return output;
    }
    if (options.pattern_kind == .literal_text) return std.unicode.utf16LeToUtf8Alloc(allocator, options.literalUtf16()) catch null;
    const host = std.unicode.utf16LeToUtf8Alloc(allocator, options.hostUtf16()) catch return null;
    defer allocator.free(host);
    return std.fmt.allocPrint(allocator, "C++ echo from {s}", .{host}) catch null;
}

fn sampleCount(metrics: *const Metrics) u64 {
    var count: u64 = 0;
    for (metrics.latency_bins) |bin| count += bin.load(.monotonic);
    return count;
}

pub fn printMetrics(phase: []const u8, options: *const types.Options, metrics: *const Metrics, elapsed_ms: u64) void {
    const echoed = metrics.echoed.load(.monotonic);
    const bytes = metrics.bytes.load(.monotonic);
    const samples = sampleCount(metrics);
    const elapsed_seconds: f64 = @as(f64, @floatFromInt(@max(elapsed_ms, 1))) / 1000;
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} elapsed_ms={d} sessions={d} echoed={d} corrupted={d} lost={d} network_errors={d} bytes={d} echo_per_sec={d:.2} MiB_per_sec={d:.2} p50_us~{d} p99_us~{d} p999_us~{d} max_us~{d} latency_sample=batch\n", .{
        phase,                                             elapsed_ms,                                                       options.session_count,                          echoed,                                         metrics.corrupted.load(.monotonic),               metrics.lost.load(.monotonic),               metrics.network_errors.load(.monotonic), bytes,
        @as(f64, @floatFromInt(echoed)) / elapsed_seconds, @as(f64, @floatFromInt(bytes)) / (1024 * 1024) / elapsed_seconds, internal.percentile(metrics, samples, 50, 100), internal.percentile(metrics, samples, 99, 100), internal.percentile(metrics, samples, 999, 1000), internal.percentile(metrics, samples, 1, 1),
    }) catch fail("client metrics format", c.ERROR_INSUFFICIENT_BUFFER);
    if (!win32.writeStdout(line)) fail("client metrics output", c.GetLastError());
}

fn printBenchLatency(workers: []const Worker) void {
    if (!bench_config.enabled) return;
    var combined = @import("bench_histogram.zig").Histogram.init();
    for (workers) |worker| {
        for (worker.bench_histogram.buckets, 0..) |samples, index| combined.buckets[index] += samples;
        combined.count += worker.bench_histogram.count;
    }
    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "bench_latency_sample=batch bench_samples={d} p50_us~{d} p99_us~{d} p999_us~{d} max_us~{d}\n", .{
        combined.count,
        combined.percentile(50, 100),
        combined.percentile(99, 100),
        combined.percentile(999, 1000),
        combined.percentile(1, 1),
    }) catch fail("client benchmark latency format", c.ERROR_INSUFFICIENT_BUFFER);
    if (!win32.writeStdout(line)) fail("client benchmark latency output", c.GetLastError());
}

pub fn runClient(options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
    var winsock = win32.Winsock.init() catch return .network;
    defer winsock.deinit();
    const extensions = rio.Extensions.load() catch return .network;
    var remote: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    if (!resolveIpv4(options, &remote)) return .network;
    const pattern = buildPattern(options) orelse {
        win32.report("payload pattern", c.ERROR_INVALID_DATA);
        return .usage;
    };
    defer allocator.free(pattern);
    if (pattern.len == 0 or (options.protocol == .udp and pattern.len > types.maximum_udp_payload)) {
        win32.report("payload pattern", c.ERROR_INVALID_DATA);
        return .usage;
    }
    const depth: usize = if (options.protocol == .tcp) options.pipeline_depth else 1;
    const maximum_attempt_bytes = contract.checkedProduct(pattern.len, depth) orelse {
        win32.report("payload batch size", c.ERROR_ARITHMETIC_OVERFLOW);
        return .usage;
    };
    if (maximum_attempt_bytes > types.maximum_tcp_batch_bytes) {
        win32.report("payload batch size", c.ERROR_ARITHMETIC_OVERFLOW);
        return .usage;
    }
    if (contract.checkedStorageBytes(options.session_count, maximum_attempt_bytes, options.memory_bytes) == null) {
        win32.report("registered storage /memory limit", c.ERROR_NOT_ENOUGH_MEMORY);
        return .usage;
    }
    const count = workerCount(options.session_count, options.worker_count);
    const workers = allocator.alloc(Worker, count) catch return .network;
    defer allocator.free(workers);
    const owners = allocator.alloc(WorkerResources, count) catch return .network;
    defer allocator.free(owners);
    var metrics: Metrics = .{};
    var fatal = std.atomic.Value(bool).init(false);
    var initialized: u32 = 0;
    var remaining = options.session_count;
    while (initialized < count) : (initialized += 1) {
        const left = count - initialized;
        const sessions = (remaining + left - 1) / left;
        const share = options.memory_bytes / options.session_count * sessions;
        if (!initializeWorker(&workers[initialized], &extensions, options, &remote, pattern, maximum_attempt_bytes, &metrics, stop, &fatal, initialized, sessions, share, &owners[initialized])) {
            fatal.store(true, .release);
            destroyWorker(&workers[initialized]);
            break;
        }
        if (!startWorker(&workers[initialized])) {
            fatal.store(true, .release);
            destroyWorker(&workers[initialized]);
            break;
        }
        remaining -= sessions;
    }
    const start = c.GetTickCount64();
    var next_report: u64 = if (options.report_seconds == 0) std.math.maxInt(u64) else start + @as(u64, options.report_seconds) * 1000;
    var all_done = false;
    var stop_posts_sent = false;
    while (!all_done) {
        const now = c.GetTickCount64();
        if (options.run_seconds != 0 and now - start >= @as(u64, options.run_seconds) * 1000) stop.store(true, .release);
        if (now >= next_report) {
            printMetrics("report", options, &metrics, now - start);
            next_report = now + @as(u64, options.report_seconds) * 1000;
        }
        if (!stop_posts_sent and (fatal.load(.acquire) or stop.load(.acquire))) {
            for (workers[0..initialized]) |*worker| postWorkerStop(worker);
            stop_posts_sent = true;
        }
        all_done = true;
        for (workers[0..initialized]) |*worker| {
            if (c.WaitForSingleObject(worker.thread, 0) == c.WAIT_TIMEOUT) all_done = false;
        }
        if (!all_done) c.Sleep(10);
    }
    for (workers[0..initialized]) |*worker| destroyWorker(worker);
    const never_claimed = contract.unclaimedEchoes(options.echo_count, metrics.claimed.load(.monotonic), stop.load(.acquire));
    if (never_claimed != 0) _ = metrics.lost.fetchAdd(never_claimed, .monotonic);
    const echoed = metrics.echoed.load(.monotonic);
    const corrupted = metrics.corrupted.load(.monotonic);
    const lost = metrics.lost.load(.monotonic);
    if (!options.quiet or options.stats) printMetrics("final", options, &metrics, c.GetTickCount64() - start);
    if (bench_config.enabled) printBenchLatency(workers[0..initialized]);
    return @fromBackingInt(@intCast(contract.classifyResult(echoed, corrupted, lost, metrics.network_errors.load(.monotonic), fatal.load(.acquire), stop.load(.acquire))));
}
