//! Native data path, worker start and stop, and run coordination.
//!
//! This is the only module that dereferences a native handle. The protocol is chosen exactly once,
//! at the entry point below, and every specialization then treats it as a compile-time constant, so
//! the per-completion path carries no runtime protocol branch at all.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const internal = @import("internal.zig");
const metrics = @import("metrics.zig");
const native = @import("native.zig");
const payload = @import("payload.zig");
const types = @import("types.zig");

const c = native.sdk.c;
const Worker = internal.worker.Worker;
const Session = internal.session.Session;
const Step = internal.session.scheduler.Step;
const Progress = internal.worker.Progress;

const allocator = std.heap.page_allocator;

/// One bounded dequeue batch and one bounded number of batches per wait, so a busy queue can never
/// starve the control path.
const completion_batch: u32 = 256;
const drain_batches: u32 = 64;
/// A worker that cannot retire its outstanding operations within this budget has a provider fault.
/// Releasing registered memory while the provider still owns it would be worse than exiting.
const shutdown_timeout_ms: u64 = 5_000;
const maximum_wait_ms: u64 = 1_000;
const iocp_retire_attempts: u32 = 64;
const stop_key: usize = 0;

/// Process-wide stop control. A console control handler can set it without a lock or an allocation.
var stop_requested = std.atomic.Value(bool).init(false);
var fatal_requested = std.atomic.Value(bool).init(false);

pub fn requestStop() void {
    stop_requested.store(true, .release);
}

/// Only an internal failure means no further progress is possible anywhere, and only then may a run
/// end for its peers. Waking them because one session lost its connection would truncate their
/// accounting.
pub fn requestFatal() void {
    fatal_requested.store(true, .release);
    stop_requested.store(true, .release);
}

fn clearControl() void {
    stop_requested.store(false, .release);
    fatal_requested.store(false, .release);
}

fn stopRequested() bool {
    return stop_requested.load(.acquire);
}

fn fatalRequested() bool {
    return fatal_requested.load(.acquire);
}

pub const InitError = error{
    Clock,
    Capacity,
    Port,
    Arena,
    Sessions,
    TimerNodes,
    TimerPositions,
    TimerHeap,
    CompletionQueue,
};

/// The named fail-fast boundaries. Each one is a real production invariant, and naming them keeps
/// the fault-injection driver exercising the same code path a live run takes.
pub fn requireNotifySuccess(status: c_int) void {
    if (status != c.ERROR_SUCCESS) native.diagnostics.failFast("RIONotify(client)", @bitCast(status));
}

pub fn requireDequeueCount(count: u32, maximum: u32) u32 {
    // RIO_CORRUPT_CQ is a hard failure rather than "no work".
    if (count == c.RIO_CORRUPT_CQ or count > maximum) {
        native.diagnostics.failFast("RIODequeueCompletion(client)", c.ERROR_INVALID_DATA);
    }
    return count;
}

pub fn requireNotificationDelivered(armed: *bool) void {
    if (!armed.*) native.diagnostics.failFast("client notification delivery transition", c.ERROR_INVALID_STATE);
    armed.* = false;
}

pub fn requireNotificationRearmed(armed: *bool) void {
    if (armed.*) native.diagnostics.failFast("client notification rearm transition", c.ERROR_INVALID_STATE);
    armed.* = true;
}

/// A completion port that refuses its control post can no longer guarantee a bounded shutdown, so
/// the process stops here rather than spinning against a port that will never wake its worker.
pub fn requireControlPost(ok: c.BOOL, native_error: u32) void {
    if (ok == c.FALSE) native.diagnostics.failFast("PostQueuedCompletionStatus(client stop)", native_error);
}

/// Closes the completion queue, but only once no session still owns an operation. Closing a queue
/// with completions still in flight would drop the provider's last reference to registered memory
/// without ever retiring it, which is exactly the release order the design forbids.
pub fn retireCompletionQueue(wrk: *Worker) void {
    for (wrk.sessions) |entry| {
        if (entry.outstanding() != 0) {
            native.diagnostics.failFast("client CQ retirement with outstanding operations", c.ERROR_IO_INCOMPLETE);
        }
    }
    wrk.completion_queue.deinit();
}

/// A worker may release its registered memory only once every operation of every generation has
/// been retired. Closing a socket starts cancellation; it does not end the lifetime of that I/O.
pub fn requireReleasePreconditions(wrk: *const Worker) void {
    if (wrk.outstanding() != 0) {
        native.diagnostics.failFast("client worker release precondition", c.ERROR_IO_INCOMPLETE);
    }
    for (wrk.sessions) |entry| {
        if (!entry.isFinished()) {
            native.diagnostics.failFast("client worker release precondition", c.ERROR_INVALID_STATE);
        }
    }
}

/// Test-only staged failure injection. It exists so the rollback path can be proven to release
/// exactly the stages it already acquired, which a live run cannot demonstrate.
pub const InitStage = enum { port, arena, sessions, timer_nodes, timer_positions, timer_heap, completion_queue };
pub var test_fail_stage: ?InitStage = null;

fn injectedFailure(stage: InitStage) bool {
    if (!builtin.is_test) return false;
    return test_fail_stage == stage;
}

/// The single runtime protocol switch of the whole client. Everything below it is specialized.
pub fn runClient(options: *const types.Options) types.ExitCode {
    return switch (options.protocol) {
        .tcp => runProtocol(.tcp, options),
        .udp => runProtocol(.udp, options),
        .none => .usage,
    };
}

fn socketType(comptime protocol: types.Protocol) c_int {
    return if (protocol == .tcp) c.SOCK_STREAM else c.SOCK_DGRAM;
}

fn ipProtocol(comptime protocol: types.Protocol) c_int {
    return if (protocol == .tcp) c.IPPROTO_TCP else c.IPPROTO_UDP;
}

fn receiveFlags(comptime protocol: types.Protocol) u32 {
    return if (protocol == .tcp) c.RIO_MSG_WAITALL else 0;
}

fn resolveTarget(options: *const types.Options, remote: *c.SOCKADDR_IN) bool {
    const target = native.endpoint.resolveIpv4(@ptrCast(&options.host), options.remote_port) orelse return false;
    remote.* = target;
    return true;
}

fn runProtocol(comptime protocol: types.Protocol, options: *const types.Options) types.ExitCode {
    internal.worker.trace.configure();
    clearControl();
    var winsock = native.winsock.Winsock.init() catch return .network;
    defer winsock.deinit();
    // The reference starts Winsock and loads the RIO extensions before it resolves the target, so
    // an unresolvable name is reported after the transport is known to exist.
    const extensions = native.rio.Extensions.load() catch return .network;
    var remote: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    if (!resolveTarget(options, &remote)) return .network;
    const pattern = payload.build(allocator, options) orelse {
        native.diagnostics.report("payload build", c.ERROR_INVALID_DATA);
        return .usage;
    };
    defer allocator.free(pattern);
    if (!payload.validate(options, pattern)) {
        native.diagnostics.report("payload validation", c.ERROR_INVALID_DATA);
        return .usage;
    }
    const clock = native.clock.Clock.init() orelse return .internal;
    const batch_bytes = pattern.len * @as(usize, options.batchCapacity());
    if (batch_bytes == 0 or batch_bytes > types.maximum_tcp_batch_bytes) {
        native.diagnostics.report("payload batch size", c.ERROR_ARITHMETIC_OVERFLOW);
        return .usage;
    }
    if (contract.checkedStorageBytes(options.session_count, batch_bytes, options.memory_bytes) == null) {
        native.diagnostics.report("registered storage budget", c.ERROR_NOT_ENOUGH_MEMORY);
        return .usage;
    }
    const workers_requested = contract.resolveWorkerCount(options.worker_count, options.session_count);
    const worker_total: u32 = @intCast(workers_requested);
    const base_shard = options.session_count / worker_total;
    const extra_shards = options.session_count % worker_total;

    const workers = allocator.alloc(Worker, worker_total) catch return .internal;
    defer allocator.free(workers);
    const snapshots = allocator.alloc(?*Progress, worker_total) catch return .internal;
    defer {
        for (snapshots) |maybe| {
            if (maybe) |snapshot| allocator.destroy(snapshot);
        }
        allocator.free(snapshots);
    }
    @memset(snapshots, null);

    var started: u32 = 0;
    var setup_failed = false;
    for (workers, 0..) |*wrk, index| {
        const sessions: u32 = base_shard + @intFromBool(index < extra_shards);
        const memory_share = (options.memory_bytes / options.session_count) * sessions;
        if (options.report_seconds != 0) {
            const snapshot = allocator.create(Progress) catch {
                setup_failed = true;
                break;
            };
            snapshot.* = .{};
            snapshots[index] = snapshot;
        }
        initializeWorker(protocol, wrk, &extensions, options, &remote, pattern, batch_bytes, sessions, memory_share, @intCast(index), &clock, snapshots[index]) catch |failure| {
            native.diagnostics.report("client worker initialization", @intCast(@intFromError(failure)));
            setup_failed = true;
            requestFatal();
            break;
        };
        if (!startWorker(protocol, wrk)) {
            setup_failed = true;
            requestFatal();
            break;
        }
        started = @intCast(index + 1);
    }

    const started_ticks = clock.nowTicks();
    var next_report_ticks = started_ticks +| clock.millisecondsToTicks(@as(u64, options.report_seconds) * 1_000);
    var stop_posts_sent = false;
    while (true) {
        const now = clock.nowTicks();
        if (options.run_seconds != 0 and
            clock.ticksToMilliseconds(now -| started_ticks) >= @as(u64, options.run_seconds) * 1_000)
        {
            requestStop();
        }
        if (stopRequested() and !stop_posts_sent) {
            for (workers[0..started]) |*wrk| postStop(wrk);
            stop_posts_sent = true;
        }
        if (options.report_seconds != 0 and now >= next_report_ticks) {
            var merged = metrics.Statistics{};
            var active: u32 = 0;
            for (snapshots[0..started]) |maybe| {
                if (maybe) |snapshot| {
                    var part = metrics.Statistics{};
                    var part_active: u32 = 0;
                    snapshot.load(&part, &part_active);
                    merged.merge(&part);
                    active +|= part_active;
                }
            }
            merged.elapsed_ms = clock.ticksToMilliseconds(now -| started_ticks);
            printLine("report", options, &merged, active);
            next_report_ticks = now +| clock.millisecondsToTicks(@as(u64, options.report_seconds) * 1_000);
        }
        var all_finished = true;
        for (workers[0..started]) |*wrk| {
            if (wrk.thread.value == null) continue;
            if (c.WaitForSingleObject(wrk.thread.value, 0) == c.WAIT_TIMEOUT) all_finished = false;
        }
        if (all_finished) break;
        c.Sleep(10);
    }

    var statistics = metrics.Statistics{};
    for (workers) |*wrk| {
        destroyWorker(wrk);
        statistics.merge(&wrk.statistics);
    }

    // A finite quota the run never claimed is a loss, exactly like the reference: those attempts
    // were asked for and never completed, so the classification reports an echo failure even when
    // the terminal cause was a worker or network failure.
    const fatal = statistics.fatal or setup_failed or fatalRequested();
    const controlled_stop = stopRequested() and !fatal;
    const unclaimed = statistics.unclaimed(options.echo_count, options.session_count, controlled_stop);
    if (unclaimed != 0) {
        statistics.lost +|= unclaimed;
        statistics.attempted +|= unclaimed;
    }
    if (controlled_stop) {
        // A controlled stop cancels the attempts that were claimed and never finished; they are
        // neither echoes nor losses, which is what the report calls cancelled.
        statistics.cancelled = statistics.attempted -|
            (statistics.echoes +| statistics.corrupted +| statistics.lost);
    } else if (fatal) {
        statistics.lost +|= statistics.attempted -|
            (statistics.echoes +| statistics.corrupted +| statistics.lost +| statistics.cancelled);
    }

    if (options.stats or !options.quiet) {
        statistics.elapsed_ms = clock.ticksToMilliseconds(clock.nowTicks() -| started_ticks);
        printLine("final", options, &statistics, 0);
    }
    printBenchLatency(workers);
    if (fatal) return .internal;
    return statistics.exitCode(controlled_stop);
}

fn printLine(label: []const u8, options: *const types.Options, statistics: *const metrics.Statistics, active: u32) void {
    var buffer: [1024]u8 = undefined;
    const line = statistics.writeLine(label, options.session_count, active, &buffer) orelse
        native.diagnostics.failFast("client metrics format", c.ERROR_INSUFFICIENT_BUFFER);
    if (!native.diagnostics.writeStdout(line)) native.diagnostics.failFast("client metrics output", c.GetLastError());
}

fn printBenchLatency(workers: []const Worker) void {
    if (!metrics.benchmark_enabled) return;
    var combined = metrics.Histogram{};
    for (workers) |wrk| {
        for (wrk.bench_histogram.buckets, 0..) |samples, index| combined.buckets[index] +|= samples;
        combined.count +|= wrk.bench_histogram.count;
    }
    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "bench_latency_sample=batch bench_samples={d} p50_us~{d} p99_us~{d} p999_us~{d} max_us~{d}\n", .{
        combined.count,
        combined.percentile(50, 100),
        combined.percentile(99, 100),
        combined.percentile(999, 1_000),
        combined.percentile(1, 1),
    }) catch native.diagnostics.failFast("client benchmark latency format", c.ERROR_INSUFFICIENT_BUFFER);
    if (!native.diagnostics.writeStdout(line)) native.diagnostics.failFast("client benchmark latency output", c.GetLastError());
}

pub fn initializeWorker(
    comptime protocol: types.Protocol,
    wrk: *Worker,
    extensions: *const native.rio.Extensions,
    options: *const types.Options,
    remote: *const c.SOCKADDR_IN,
    pattern: []const u8,
    batch_bytes: usize,
    session_count: u32,
    memory_share: u64,
    index: u32,
    clock: *const native.clock.Clock,
    snapshot: ?*Progress,
) InitError!void {
    wrk.* = .{};
    errdefer wrk.release(allocator);
    wrk.index = index;
    wrk.session_count = session_count;
    wrk.options = options;
    wrk.clock = clock.*;
    wrk.payload_bytes = pattern.len;
    wrk.remote_address = remote.*;
    wrk.api = &extensions.rio;
    wrk.connect_ex = extensions.connect_ex;
    wrk.receive_flags = receiveFlags(protocol);
    wrk.timeout_ticks = clock.millisecondsToTicks(@as(u64, options.timeout_seconds) * 1_000);
    wrk.interval_ticks = clock.millisecondsToTicks(@as(u64, options.interval_milliseconds));
    wrk.reconnect_enabled = options.reconnect_seconds != null;
    wrk.reconnect_ticks = if (options.reconnect_seconds) |seconds| clock.millisecondsToTicks(@as(u64, seconds) * 1_000) else 0;
    if (clock.frequency == 0) return error.Clock;

    const arena_bytes = contract.checkedStorageBytes(session_count, batch_bytes, memory_share) orelse {
        native.diagnostics.report("client worker arena budget", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Capacity;
    };
    if (options.cq_capacity < session_count * 2 or arena_bytes > std.math.maxInt(u32)) {
        native.diagnostics.report("client worker completion queue capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Capacity;
    }
    wrk.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    if (wrk.port.value == null or wrk.port.value == c.INVALID_HANDLE_VALUE) {
        native.diagnostics.report("CreateIoCompletionPort(client worker)", c.GetLastError());
        return error.Port;
    }
    if (injectedFailure(.port)) return error.Port;
    const stride: u32 = @intCast(batch_bytes);
    wrk.arena = native.arena.Arena.create(&extensions.rio, session_count, stride) catch |failure| {
        native.diagnostics.report("RIORegisterBuffer(client arena)", c.ERROR_NOT_ENOUGH_MEMORY);
        return switch (failure) {
            error.Capacity => error.Capacity,
            error.Allocation => error.Capacity,
            error.VirtualAlloc => error.Arena,
            error.Registration => error.Arena,
        };
    };
    if (injectedFailure(.arena)) return error.Arena;
    for (0..session_count) |slot| {
        const window = wrk.arena.sendBytes(@intCast(slot), stride) orelse return error.Arena;
        payload.fillRepeated(window, pattern);
    }
    wrk.sessions = allocator.alloc(Session, session_count) catch return error.Sessions;
    if (injectedFailure(.sessions)) return error.Sessions;
    wrk.steps = allocator.alloc(Step, internal.stepRegionBytes(session_count) * internal.step_levels) catch return error.Sessions;
    wrk.timer_nodes = allocator.alloc(internal.timer.Node, session_count) catch return error.TimerNodes;
    if (injectedFailure(.timer_nodes)) return error.TimerNodes;
    wrk.timer_positions = allocator.alloc(u32, session_count) catch return error.TimerPositions;
    if (injectedFailure(.timer_positions)) return error.TimerPositions;
    wrk.timers = internal.timer.Heap.init(wrk.timer_nodes, wrk.timer_positions) catch return error.TimerHeap;
    if (injectedFailure(.timer_heap)) return error.TimerHeap;
    for (wrk.sessions, 0..) |*entry, position| {
        entry.* = .{};
        entry.index = @intCast(position);
        entry.generation = 1;
    }
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = wrk.port.get();
    notification.Iocp.CompletionKey = @ptrCast(wrk);
    notification.Iocp.Overlapped = @ptrCast(&wrk.notification_overlapped);
    wrk.completion_queue.reset(&extensions.rio, extensions.rio.createCq(options.cq_capacity, &notification));
    if (!wrk.completion_queue.valid()) {
        native.diagnostics.report("RIOCreateCompletionQueue(client)", @bitCast(c.WSAGetLastError()));
        return error.CompletionQueue;
    }
    if (injectedFailure(.completion_queue)) return error.CompletionQueue;
    if (snapshot) |value| {
        wrk.progress = value;
        const publish_ms: u64 = @min(@as(u64, options.report_seconds) * 1_000, 50);
        wrk.progress_interval_ticks = clock.millisecondsToTicks(publish_ms);
        wrk.next_progress_ticks = 0;
    }
    wrk.phase = .starting;
}

/// The thread entry is a compile-time specialization of the worker loop, so the protocol never
/// appears as a branch inside the completion path.
fn ThreadEntry(comptime protocol: types.Protocol) type {
    return struct {
        fn run(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
            const wrk: *Worker = @ptrCast(@alignCast(parameter.?));
            runWorker(protocol, wrk);
            return 0;
        }
    };
}

fn startWorker(comptime protocol: types.Protocol, wrk: *Worker) bool {
    wrk.thread.reset(c.CreateThread(null, 0, ThreadEntry(protocol).run, @ptrCast(wrk), 0, null));
    if (wrk.thread.value == null) {
        native.diagnostics.report("CreateThread(client worker)", c.GetLastError());
        return false;
    }
    return true;
}

fn postStop(wrk: *Worker) void {
    requireControlPost(c.PostQueuedCompletionStatus(wrk.port.get(), 0, stop_key, null), c.GetLastError());
}

fn joinWorker(wrk: *Worker) void {
    if (wrk.thread.value != null and c.WaitForSingleObject(wrk.thread.value, c.INFINITE) != c.WAIT_OBJECT_0) {
        native.diagnostics.failFast("WaitForSingleObject(client worker)", c.GetLastError());
    }
}

fn destroyWorker(wrk: *Worker) void {
    const ran = wrk.thread.value != null;
    joinWorker(wrk);
    // The precondition only applies to a worker whose loop actually reached its terminal state.
    if (ran) requireReleasePreconditions(wrk);
    wrk.release(allocator);
}

/// The completion-driven worker loop.
///
/// The acquired completions of one wait are always settled before the stop decision and before any
/// timer expires, which is what makes a controlled stop and a deadline arbitration exact rather than
/// order-dependent. The notification is re-armed only after both, and only while work is in flight.
fn runWorker(comptime protocol: types.Protocol, wrk: *Worker) void {
    wrk.phase = .running;
    const started = wrk.clock.nowTicks();
    const run_deadline: ?u64 = if (wrk.options.run_seconds == 0)
        null
    else
        started +| wrk.clock.millisecondsToTicks(@as(u64, wrk.options.run_seconds) * 1_000);

    {
        const region = wrk.acquireRegion();
        dispatch(protocol, wrk, internal.session.scheduler.start(wrk, started, region));
        wrk.releaseRegion();
    }
    maybeArm(wrk);
    while (true) {
        const now = wrk.clock.nowTicks();
        wrk.publish(now, false);
        if (internal.session.scheduler.allFinished(wrk) or wrk.statistics.fatal) break;
        // Even an already-due stop or deadline permits one bounded zero-wait drain: queued
        // completions are never skipped, and the drain never runs ahead of the control path.
        const maximum_ms: u64 = if (stopRequested())
            0
        else if (run_deadline) |deadline|
            @min(wrk.clock.waitMillisecondsUntil(deadline, now), maximum_wait_ms)
        else
            maximum_wait_ms;
        const wait_ticks = internal.session.scheduler.waitTicks(wrk, now, wrk.clock.millisecondsToTicks(maximum_ms));
        const wait_ms: u32 = @intCast(@min(wrk.clock.ticksToWaitMilliseconds(wait_ticks), std.math.maxInt(u32)));
        waitAndDrain(protocol, wrk, wait_ms);
        const poll_now = wrk.clock.nowTicks();
        if (stopRequested() or wrk.stopping) break;
        if (run_deadline) |deadline| {
            if (poll_now >= deadline) break;
        }
        if (wrk.statistics.fatal) break;
        {
            const region = wrk.acquireRegion();
            dispatch(protocol, wrk, internal.session.scheduler.poll(wrk, poll_now, region));
            wrk.releaseRegion();
        }
        maybeArm(wrk);
    }
    wrk.phase = .draining;
    shutdownWorker(protocol, wrk);
    wrk.publish(wrk.clock.nowTicks(), true);
    wrk.phase = .stopped;
}

/// One blocking wait for any packet, then a bounded drain of the completion queue. A ConnectEx
/// completion and a RIO notification arrive through the same port, so both are observed together.
fn waitAndDrain(comptime protocol: types.Protocol, wrk: *Worker, wait_ms: u32) void {
    var transferred: c.DWORD = 0;
    var key: usize = 0;
    var overlapped: [*c]c.OVERLAPPED = null;
    const ok = c.GetQueuedCompletionStatus(wrk.port.get(), &transferred, &key, &overlapped, wait_ms);
    const native_error: u32 = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS;
    if (overlapped == &wrk.notification_overlapped) {
        if (ok == c.FALSE) native.diagnostics.failFast("GetQueuedCompletionStatus(client notification)", native_error);
        if (key != @intFromPtr(wrk)) native.diagnostics.failFast("client RIO notification key", c.ERROR_INVALID_DATA);
        requireNotificationDelivered(&wrk.completion_queue.armed);
        wrk.notification_deliveries +|= 1;
    } else if (overlapped == null) {
        if (ok == c.FALSE and native_error == c.WAIT_TIMEOUT) {
            if (wrk.outstanding() != 0) wrk.timeout_wakeups_while_outstanding +|= 1;
        } else if (key != stop_key) {
            native.diagnostics.failFast("unexpected client IOCP packet", c.ERROR_INVALID_DATA);
        }
    } else {
        if (key == 0 or key > wrk.session_count) {
            native.diagnostics.failFast("unexpected ConnectEx completion key", c.ERROR_INVALID_DATA);
        }
        const entry = &wrk.sessions[key - 1];
        if (overlapped != &entry.connect_overlapped) {
            native.diagnostics.failFast("unexpected ConnectEx completion identity", c.ERROR_INVALID_DATA);
        }
        handleConnectCompletion(protocol, wrk, entry, ok != c.FALSE, native_error);
    }
    drainRio(protocol, wrk, drain_batches);
}

pub fn drainRio(comptime protocol: types.Protocol, wrk: *Worker, budget: u32) void {
    var results: [completion_batch]c.RIORESULT = undefined;
    var batches: u32 = 0;
    while (batches < budget) : (batches += 1) {
        const count = requireDequeueCount(wrk.api.?.dequeue(wrk.completion_queue.value, &results, completion_batch), completion_batch);
        if (count == 0) return;
        for (results[0..count]) |result| handleRioResult(protocol, wrk, result);
    }
}

/// Re-arms the completion queue only while work is in flight, so a busy worker never pays for a
/// redundant notification and an idle queue never leaves a notification the provider still owns.
pub fn maybeArm(wrk: *Worker) void {
    if (wrk.completion_queue.armed) return;
    if (wrk.outstanding() == 0) return;
    requireNotifySuccess(wrk.api.?.notify(wrk.completion_queue.value));
    requireNotificationRearmed(&wrk.completion_queue.armed);
    wrk.notification_arms +|= 1;
}

fn handleConnectCompletion(
    comptime protocol: types.Protocol,
    wrk: *Worker,
    entry: *Session,
    ok: bool,
    native_error: u32,
) void {
    if (!entry.connect_outstanding) native.diagnostics.failFast("ConnectEx outstanding count", c.ERROR_INVALID_DATA);
    entry.connect_outstanding = false;
    if (entry.state != .connecting) {
        settleDrain(protocol, wrk, entry);
        return;
    }
    if (!ok) {
        native.diagnostics.report("ConnectEx completion", native_error);
        failSession(protocol, wrk, entry.index);
        return;
    }
    if (!native.endpoint.updateConnectContext(entry.socket.value)) {
        failSession(protocol, wrk, entry.index);
        return;
    }
    if (!createRequestQueue(wrk, entry)) {
        failSession(protocol, wrk, entry.index);
        return;
    }
    {
        const region = wrk.acquireRegion();
        dispatch(protocol, wrk, internal.session.scheduler.onConnected(wrk, entry.index, wrk.clock.nowTicks(), region));
        wrk.releaseRegion();
    }
}

pub fn handleRioResult(comptime protocol: types.Protocol, wrk: *Worker, result: c.RIORESULT) void {
    const raw = result.RequestContext orelse
        native.diagnostics.failFast("client RIO RequestContext", c.ERROR_INVALID_DATA);
    const decoded = native.completion.decode(@intFromPtr(raw)) orelse
        native.diagnostics.failFast("client RIO RequestContext", c.ERROR_INVALID_DATA);
    if (decoded.index >= wrk.session_count) {
        native.diagnostics.failFast("client RIO RequestContext index", c.ERROR_INVALID_DATA);
    }
    const entry = &wrk.sessions[decoded.index];
    // Native accounting is retired first and unconditionally: a completion of a retired generation
    // still has to leave the ledger, it simply must not steer the live state machine.
    switch (decoded.operation) {
        .send => {
            if (entry.send_outstanding == 0) native.diagnostics.failFast("client send completion accounting", c.ERROR_INVALID_DATA);
            entry.send_outstanding -= 1;
        },
        .receive => {
            if (entry.receive_outstanding == 0) native.diagnostics.failFast("client receive completion accounting", c.ERROR_INVALID_DATA);
            entry.receive_outstanding -= 1;
        },
        .connect => native.diagnostics.failFast("client RIO connect completion", c.ERROR_INVALID_DATA),
        .generation_drained => native.diagnostics.failFast("client RIO drained completion", c.ERROR_INVALID_DATA),
    }
    // A completion collected before an earlier one in the same batch moved this generation to
    // Closing is still needed for accounting, but it must not resume the attempt.
    if (entry.state != .active or decoded.generation != entry.generation) {
        settleDrain(protocol, wrk, entry);
        return;
    }
    if (result.Status != 0) {
        failSession(protocol, wrk, entry.index);
        return;
    }
    switch (decoded.operation) {
        .send => {
            if (result.BytesTransferred == 0 or result.BytesTransferred > entry.attempt_bytes - entry.send_offset) {
                failSession(protocol, wrk, entry.index);
                return;
            }
            wrk.statistics.sent_bytes +|= result.BytesTransferred;
            entry.send_offset += result.BytesTransferred;
            if (entry.send_offset < entry.attempt_bytes) {
                // A partial send re-posts the remainder of the same registered window, so one
                // attempt stays one outstanding RIOSend.
                if (!postSend(wrk, entry)) failSession(protocol, wrk, entry.index);
                return;
            }
            entry.send_done = true;
        },
        .receive => {
            if (protocol == .tcp and result.BytesTransferred != entry.attempt_bytes) {
                failSession(protocol, wrk, entry.index);
                return;
            }
            wrk.statistics.received_bytes +|= result.BytesTransferred;
            entry.received_bytes = result.BytesTransferred;
            entry.receive_done = true;
        },
        .connect, .generation_drained => unreachable,
    }
    if (!entry.send_done or !entry.receive_done) return;
    const expected = wrk.arena.sendBytes(entry.index, @intCast(entry.attempt_bytes)) orelse
        native.diagnostics.failFast("client send window", c.ERROR_INVALID_DATA);
    const echoed: []const u8 = if (entry.received_bytes == 0)
        &[_]u8{}
    else
        (wrk.arena.receiveBytes(entry.index, @intCast(entry.received_bytes)) orelse
            native.diagnostics.failFast("client receive window", c.ERROR_INVALID_DATA));
    // Exact comparison: a short read is a failure, never a partial success. A short TCP read is
    // already a connection failure above; a short datagram is a corrupted echo.
    const corrupt = !payload.verify(echoed, expected[0..entry.attempt_bytes]);
    {
        const region = wrk.acquireRegion();
        dispatch(protocol, wrk, internal.session.scheduler.onAttemptSettled(wrk, entry.index, wrk.clock.nowTicks(), corrupt, region));
        wrk.releaseRegion();
    }
}

/// Runs the steps the scheduler decided on. A failed post leaves the generation closing, so the
/// remaining precomputed steps for that same session are skipped rather than cascading.
fn dispatch(comptime protocol: types.Protocol, wrk: *Worker, steps: []const Step) void {
    var failed_session: ?u32 = null;
    for (steps) |step| {
        const step_index = switch (step) {
            .connect => |value| value,
            .close => |value| value,
            .send => |value| value.index,
            .receive => |value| value.index,
        };
        if (failed_session) |failed| {
            if (failed == step_index) continue;
        }
        switch (step) {
            .connect => |value| postConnect(protocol, wrk, value),
            .send => |value| {
                if (!postSend(wrk, &wrk.sessions[value.index])) {
                    failed_session = step_index;
                    failSession(protocol, wrk, step_index);
                }
            },
            .receive => |value| {
                if (!postReceive(wrk, &wrk.sessions[value.index])) {
                    failed_session = step_index;
                    failSession(protocol, wrk, step_index);
                }
            },
            .close => |value| closeGeneration(protocol, wrk, value),
        }
    }
}

fn postConnect(comptime protocol: types.Protocol, wrk: *Worker, index: u32) void {
    const entry = &wrk.sessions[index];
    if (entry.state != .connecting) return;
    entry.socket.deinit();
    entry.request_queue = c.RIO_INVALID_RQ;
    entry.socket.reset(native.socket.registered(socketType(protocol), ipProtocol(protocol)));
    if (entry.socket.value == c.INVALID_SOCKET) {
        native.diagnostics.report("client socket creation", @bitCast(c.WSAGetLastError()));
        failSession(protocol, wrk, index);
        return;
    }
    if (!native.socket.configure(entry.socket.value, wrk.options.socket_buffer_bytes, protocol == .tcp)) {
        failSession(protocol, wrk, index);
        return;
    }
    if (!native.endpoint.bindLocal(entry.socket.value, wrk.options.local_port)) {
        failSession(protocol, wrk, index);
        return;
    }
    if (protocol == .udp) {
        if (!native.endpoint.connectUdp(entry.socket.value, &wrk.remote_address) or !createRequestQueue(wrk, entry)) {
            failSession(protocol, wrk, index);
            return;
        }
        {
            const region = wrk.acquireRegion();
            dispatch(protocol, wrk, internal.session.scheduler.onConnected(wrk, index, wrk.clock.nowTicks(), region));
            wrk.releaseRegion();
        }
        return;
    }
    const socket_handle: c.HANDLE = @ptrFromInt(entry.socket.value);
    if (c.CreateIoCompletionPort(socket_handle, wrk.port.get(), index + 1, 0) != wrk.port.get()) {
        native.diagnostics.report("CreateIoCompletionPort(ConnectEx socket)", c.GetLastError());
        failSession(protocol, wrk, index);
        return;
    }
    entry.connect_overlapped = std.mem.zeroes(c.OVERLAPPED);
    entry.connect_outstanding = true;
    internal.session.scheduler.anchorPostedTimeout(wrk, index, wrk.clock.nowTicks());
    if (native.endpoint.beginConnect(wrk.connect_ex.?, entry.socket.value, &wrk.remote_address, &entry.connect_overlapped)) |code| {
        entry.connect_outstanding = false;
        native.diagnostics.report("ConnectEx", @bitCast(code));
        failSession(protocol, wrk, index);
    }
}

fn createRequestQueue(wrk: *Worker, entry: *Session) bool {
    entry.request_queue = wrk.api.?.createRq(
        entry.socket.value,
        1,
        1,
        1,
        1,
        wrk.completion_queue.value,
        wrk.completion_queue.value,
        @ptrCast(entry),
    );
    if (entry.request_queue == c.RIO_INVALID_RQ) {
        native.diagnostics.report("RIOCreateRequestQueue(client)", @bitCast(c.WSAGetLastError()));
        return false;
    }
    return true;
}

fn postSend(wrk: *Worker, entry: *Session) bool {
    const remaining: u32 = @intCast(entry.attempt_bytes - entry.send_offset);
    const context = native.completion.encode(entry.index, entry.generation, native.completion.no_send_slot, .send) orelse {
        native.diagnostics.report("client send context", c.ERROR_INVALID_DATA);
        return false;
    };
    var buffer = wrk.arena.sendViewFrom(entry.index, @intCast(entry.send_offset), remaining) orelse {
        native.diagnostics.report("client send window", c.ERROR_INVALID_DATA);
        return false;
    };
    if (!wrk.api.?.send(entry.request_queue, &buffer, 0, context)) {
        native.diagnostics.report("RIOSend(client)", @bitCast(c.WSAGetLastError()));
        return false;
    }
    entry.send_outstanding += 1;
    entry.send_posted_bytes = remaining;
    return true;
}

fn postReceive(wrk: *Worker, entry: *Session) bool {
    const context = native.completion.encode(entry.index, entry.generation, native.completion.no_send_slot, .receive) orelse {
        native.diagnostics.report("client receive context", c.ERROR_INVALID_DATA);
        return false;
    };
    var buffer = wrk.arena.receiveView(entry.index, @intCast(entry.attempt_bytes)) orelse {
        native.diagnostics.report("client receive window", c.ERROR_INVALID_DATA);
        return false;
    };
    if (!wrk.api.?.receive(entry.request_queue, &buffer, wrk.receive_flags, context)) {
        native.diagnostics.report("RIOReceive(client)", @bitCast(c.WSAGetLastError()));
        return false;
    }
    entry.receive_outstanding += 1;
    entry.receive_posted_bytes = @intCast(entry.attempt_bytes);
    return true;
}

fn failSession(comptime protocol: types.Protocol, wrk: *Worker, index: u32) void {
    const region = wrk.acquireRegion();
    dispatch(protocol, wrk, internal.session.scheduler.onTransportFailure(wrk, index, region));
    wrk.releaseRegion();
}

/// The first phase of retirement: closing the socket starts cancellation, it does not end the
/// lifetime of the pending operations, so the generation only finishes once every completion has
/// been dequeued.
fn closeGeneration(comptime protocol: types.Protocol, wrk: *Worker, index: u32) void {
    const entry = &wrk.sessions[index];
    entry.socket.deinit();
    entry.request_queue = c.RIO_INVALID_RQ;
    settleDrain(protocol, wrk, entry);
}

fn settleDrain(comptime protocol: types.Protocol, wrk: *Worker, entry: *Session) void {
    if (entry.state != .closing) return;
    if (!entry.generationDrained()) return;
    const region = wrk.acquireRegion();
    dispatch(protocol, wrk, internal.session.scheduler.onGenerationDrained(wrk, entry.index, wrk.clock.nowTicks(), region));
    wrk.releaseRegion();
}

/// Quiesces native I/O and releases resources in the order the design fixes. A provider that never
/// retires an operation is a hard failure: unmapping registered memory that is still referenced
/// would corrupt the process rather than report the fault.
fn shutdownWorker(comptime protocol: types.Protocol, wrk: *Worker) void {
    internal.session.scheduler.beginShutdown(wrk);
    for (wrk.sessions) |*entry| {
        entry.socket.deinit();
        entry.request_queue = c.RIO_INVALID_RQ;
        if (entry.state != .done and entry.generationDrained()) {
            const region = wrk.acquireRegion();
            _ = internal.session.scheduler.onGenerationDrained(wrk, entry.index, wrk.clock.nowTicks(), region);
            wrk.releaseRegion();
        }
    }
    const deadline = wrk.clock.nowTicks() +| wrk.clock.millisecondsToTicks(shutdown_timeout_ms);
    while (wrk.outstanding() != 0) {
        if (wrk.clock.nowTicks() >= deadline) {
            native.diagnostics.failFast("client shutdown drain", c.ERROR_IO_INCOMPLETE);
        }
        waitAndDrain(protocol, wrk, 1);
        for (wrk.sessions) |*entry| settleDrain(protocol, wrk, entry);
    }
    // Retire any notification packet still queued before the completion queue is closed, so no
    // provider reference to this worker's notification OVERLAPPED outlives its owner.
    var transferred: c.DWORD = 0;
    var key: usize = 0;
    var overlapped: [*c]c.OVERLAPPED = null;
    var attempts: u32 = 0;
    while (attempts < iocp_retire_attempts) : (attempts += 1) {
        if (c.GetQueuedCompletionStatus(wrk.port.get(), &transferred, &key, &overlapped, 0) == c.FALSE) break;
        if (overlapped == &wrk.notification_overlapped) {
            _ = wrk.completion_queue.onDelivery();
        } else if (overlapped != null) {
            drainRio(protocol, wrk, 1);
        }
        overlapped = null;
    }
    retireCompletionQueue(wrk);
}

test "the parted shard sizes always cover every session" {
    for (1..8) |workers| {
        for (1..40) |sessions| {
            const count: u32 = @intCast(sessions);
            const resolved = contract.resolveWorkerCount(@intCast(workers), count);
            const base = count / resolved;
            const extra = count % resolved;
            var total_shards: u32 = 0;
            for (0..resolved) |index| total_shards += @intCast(base + @intFromBool(index < extra));
            try std.testing.expectEqual(count, total_shards);
        }
    }
}
