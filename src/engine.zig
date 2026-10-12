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
/// Upper bound for an ordinary wait; generation drain grace is kept by the pure timer heap.
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

/// An idle, never-started fixture may retire its queue directly. A started worker retires its CQ
/// only inside Worker.release, after the coordinator's join and ownership barriers.
pub fn retireCompletionQueue(wrk: *Worker) void {
    for (wrk.transport.slots) |slot| {
        if (slot.outstanding() != 0) {
            native.diagnostics.failFast("client CQ retirement with outstanding operations", c.ERROR_IO_INCOMPLETE);
        }
    }
    if (wrk.started) native.diagnostics.failFast("client CQ retirement outside worker release", c.ERROR_INVALID_STATE);
    wrk.transport.completion_queue.deinit();
}

/// A worker may release its registered memory only once every operation of every generation has
/// been retired. Closing a socket starts cancellation; it does not end the lifetime of that I/O.
pub fn requireReleasePreconditions(wrk: *const Worker) void {
    wrk.requireReleasePreconditions();
}

fn initializationError(wrk: *Worker, tag: InitError, failure: types.Failure) InitError {
    wrk.initialization_failure = failure;
    return tag;
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
    // Pacing is expressed in milliseconds, so the run asks for the finer wait granularity the
    // reference requests and releases it on every exit path.
    const paced = options.interval_milliseconds != 0;
    const timer_resolution_error = if (paced) c.timeBeginPeriod(1) else 0;
    if (timer_resolution_error != 0) {
        native.diagnostics.report("timeBeginPeriod(client pacing)", timer_resolution_error);
        return .internal;
    }
    defer if (paced) {
        _ = c.timeEndPeriod(1);
    };
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
    for (workers) |*wrk| wrk.* = .{};
    const snapshots = allocator.alloc(?*Progress, worker_total) catch return .internal;
    defer {
        for (snapshots) |maybe| {
            if (maybe) |snapshot| allocator.destroy(snapshot);
        }
        allocator.free(snapshots);
    }
    @memset(snapshots, null);

    var initialized: u32 = 0;
    var started: u32 = 0;
    var setup_failed = false;
    for (workers, 0..) |*wrk, index| {
        const sessions: u32 = base_shard + @intFromBool(index < extra_shards);
        const memory_share = (options.memory_bytes / options.session_count) * sessions;
        if (options.report_seconds != 0) {
            const snapshot = allocator.create(Progress) catch {
                setup_failed = true;
                requestFatal();
                break;
            };
            snapshot.* = .{};
            snapshots[index] = snapshot;
        }
        switch (initializeWorkerResult(protocol, wrk, &extensions, options, &remote, pattern, batch_bytes, sessions, memory_share, @intCast(index), &clock, snapshots[index])) {
            .success => {},
            .failure => |failure| {
                native.diagnostics.report(failure.stage, failure.native_code);
                setup_failed = true;
                requestFatal();
                break;
            },
        }
        initialized = @intCast(index + 1);
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

    // Join every running worker before any release precondition can terminate the process.
    for (workers[0..started]) |*wrk| joinWorker(wrk);
    // Audit the whole ownership barrier before releasing the first worker's storage.
    for (workers[0..initialized]) |*wrk| requireReleasePreconditions(wrk);
    var statistics = metrics.Statistics{};
    for (workers[0..initialized]) |*wrk| {
        destroyWorker(wrk);
        statistics.merge(&wrk.core.statistics);
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
    printBenchLatency(workers[0..initialized]);
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
        for (wrk.core.bench_histogram.buckets, 0..) |samples, index| combined.buckets[index] +|= samples;
        combined.count +|= wrk.core.bench_histogram.count;
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

/// Production initialization returns the original diagnostic payload; the error-set entry point
/// below remains a compatibility API for callers that only classify the construction stage.
pub fn initializeWorkerResult(
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
) types.Result(void) {
    initializeWorker(protocol, wrk, extensions, options, remote, pattern, batch_bytes, session_count, memory_share, index, clock, snapshot) catch {
        return .{ .failure = wrk.initialization_failure orelse
            native.diagnostics.failFast("client initialization error payload", c.ERROR_INVALID_DATA) };
    };
    return .{ .success = {} };
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
    wrk.core.index = index;
    wrk.core.session_count = session_count;
    wrk.core.options = options;
    wrk.clock = clock.*;
    wrk.core.ticks_per_second = clock.frequency;
    wrk.core.payload_bytes = pattern.len;
    wrk.transport.remote_address = remote.*;
    wrk.transport.api = &extensions.rio;
    wrk.transport.connect_ex = extensions.connect_ex;
    wrk.transport.receive_flags = receiveFlags(protocol);
    wrk.core.timeout_ticks = clock.millisecondsToTicks(@as(u64, options.timeout_seconds) * 1_000);
    wrk.core.interval_ticks = clock.millisecondsToTicks(@as(u64, options.interval_milliseconds));
    wrk.core.reconnect_enabled = options.reconnect_seconds != null;
    wrk.core.drain_grace_ticks = clock.millisecondsToTicks(internal.drain_grace_milliseconds);
    wrk.core.reconnect_ticks = if (options.reconnect_seconds) |seconds| clock.millisecondsToTicks(@as(u64, seconds) * 1_000) else 0;
    if (clock.frequency == 0) return initializationError(wrk, error.Clock, .{
        .stage = "QueryPerformanceFrequency(client)",
        .native_code = c.ERROR_INVALID_DATA,
        .domain = .invariant,
    });

    const arena_bytes = contract.checkedStorageBytes(session_count, batch_bytes, memory_share) orelse {
        return initializationError(wrk, error.Capacity, .{ .stage = "client worker arena budget", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .capacity });
    };
    if (options.cq_capacity < session_count * 2 or arena_bytes > std.math.maxInt(u32)) {
        return initializationError(wrk, error.Capacity, .{ .stage = "client worker completion queue capacity", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .capacity });
    }
    wrk.transport.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    if (wrk.transport.port.value == null or wrk.transport.port.value == c.INVALID_HANDLE_VALUE) {
        return initializationError(wrk, error.Port, .{ .stage = "CreateIoCompletionPort(client worker)", .native_code = c.GetLastError(), .domain = .win32 });
    }
    if (injectedFailure(.port)) return initializationError(wrk, error.Port, .{ .stage = "client injected port failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    const stride: u32 = @intCast(batch_bytes);
    wrk.transport.arena = switch (native.arena.Arena.createResult(&extensions.rio, session_count, stride)) {
        .success => |arena| arena,
        .failure => |failure| return initializationError(wrk, if (failure.domain == .capacity or failure.domain == .allocation) error.Capacity else error.Arena, failure),
    };
    if (injectedFailure(.arena)) return initializationError(wrk, error.Arena, .{ .stage = "client injected arena failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    for (0..session_count) |slot| {
        const window = wrk.transport.arena.sendBytes(@intCast(slot), stride) orelse return initializationError(wrk, error.Arena, .{ .stage = "client send window", .native_code = c.ERROR_INVALID_DATA, .domain = .invariant });
        payload.fillRepeated(window, pattern);
    }
    wrk.core.sessions = allocator.alloc(Session, session_count) catch return initializationError(wrk, error.Sessions, .{ .stage = "client worker sessions allocation", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .allocation });
    for (wrk.core.sessions, 0..) |*entry, position| {
        entry.* = .{};
        entry.index = @intCast(position);
    }
    if (injectedFailure(.sessions)) return initializationError(wrk, error.Sessions, .{ .stage = "client injected sessions failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    wrk.core.steps = allocator.alloc(Step, internal.stepRegionBytes(session_count) * internal.step_levels) catch return initializationError(wrk, error.Sessions, .{ .stage = "client worker actions allocation", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .allocation });
    wrk.core.timer_nodes = allocator.alloc(internal.timer.Node, session_count) catch return initializationError(wrk, error.TimerNodes, .{ .stage = "client worker timer nodes allocation", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .allocation });
    if (injectedFailure(.timer_nodes)) return initializationError(wrk, error.TimerNodes, .{ .stage = "client injected timer nodes failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    wrk.core.timer_positions = allocator.alloc(u32, session_count) catch return initializationError(wrk, error.TimerPositions, .{ .stage = "client worker timer positions allocation", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .allocation });
    if (injectedFailure(.timer_positions)) return initializationError(wrk, error.TimerPositions, .{ .stage = "client injected timer positions failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    wrk.core.timers = internal.timer.Heap.init(wrk.core.timer_nodes, wrk.core.timer_positions) catch return initializationError(wrk, error.TimerHeap, .{ .stage = "client timer heap initialization", .native_code = c.ERROR_INVALID_DATA, .domain = .invariant });
    if (injectedFailure(.timer_heap)) return initializationError(wrk, error.TimerHeap, .{ .stage = "client injected timer heap failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
    wrk.transport.slots = allocator.alloc(native.transport.Slot, session_count) catch return initializationError(wrk, error.Sessions, .{ .stage = "client worker transport slots allocation", .native_code = c.ERROR_NOT_ENOUGH_MEMORY, .domain = .allocation });
    for (wrk.transport.slots) |*slot| slot.* = .{};
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = wrk.transport.port.get();
    notification.Iocp.CompletionKey = @ptrCast(wrk);
    wrk.transport.notification_owner = @ptrCast(wrk);
    notification.Iocp.Overlapped = @ptrCast(&wrk.transport.notification_overlapped);
    wrk.transport.completion_queue.reset(&extensions.rio, extensions.rio.createCq(options.cq_capacity, &notification));
    if (!wrk.transport.completion_queue.valid()) {
        return initializationError(wrk, error.CompletionQueue, .{ .stage = "RIOCreateCompletionQueue(client)", .native_code = @bitCast(c.WSAGetLastError()), .domain = .winsock });
    }
    if (injectedFailure(.completion_queue)) return initializationError(wrk, error.CompletionQueue, .{ .stage = "client injected completion queue failure", .native_code = c.ERROR_INVALID_STATE, .domain = .invariant });
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
    wrk.started = true;
    return true;
}

fn postStop(wrk: *Worker) void {
    requireControlPost(c.PostQueuedCompletionStatus(wrk.transport.port.get(), 0, stop_key, null), c.GetLastError());
}

fn joinWorker(wrk: *Worker) void {
    if (wrk.joined) return;
    if (wrk.thread.value != null and c.WaitForSingleObject(wrk.thread.value, c.INFINITE) != c.WAIT_OBJECT_0) {
        native.diagnostics.failFast("WaitForSingleObject(client worker)", c.GetLastError());
    }
    if (wrk.started) wrk.joined = true;
}

fn destroyWorker(wrk: *Worker) void {
    joinWorker(wrk);
    wrk.release(allocator);
}

/// A native post either failed with its original diagnostic payload, or was accepted. Inline
/// transport events use the same normalized completion path as dequeued native completions.
pub const Posted = struct {
    posted_at: ?u64 = null,
    completion: ?internal.worker.Completion = null,
};
pub const PostResult = types.Result(Posted);

/// Statically specialized runtime. Transport supplies connect/send/receive/close, normalized
/// completion delivery, byte views, liveness and drain checks; Clock supplies numeric tick/time
/// conversions. A recorder can implement those methods without Winsock or a completion port.
pub fn WorkerRuntime(comptime Transport: type, comptime Clock: type) type {
    return struct {
        const Self = @This();
        core: *internal.worker.Core,
        transport: *Transport,
        clock: *Clock,
        owner: ?*Worker = null,

        pub fn deliver(self: *Self, event: internal.worker.Event) void {
            const region = self.core.acquireRegion();
            if (region.len == 0) return;
            defer self.core.releaseRegion();
            const actions = self.core.onEvent(event, self.clock.nowTicks(), region);
            self.dispatch(actions);
        }

        pub fn handleCompletion(self: *Self, completion: internal.worker.Completion) void {
            if (completion.index >= self.core.sessions.len) self.transport.invariantFailure("client completion index");
            switch (completion.operation) {
                .send, .receive => {
                    if (completion.bytes > self.core.sessions[completion.index].attempt_bytes) self.transport.invariantFailure("client completion byte count");
                },
                .connect, .generation_drained => {
                    if (completion.bytes != 0) self.transport.invariantFailure("client completion byte count");
                },
            }
            self.core.statistics.sent_bytes = self.transport.sentBytes();
            if (completion.operation == .generation_drained) {
                self.deliver(.{ .generation_drained = completion.index });
                return;
            }
            if (!self.transport.isLive(completion)) return;
            if (completion.status != 0) {
                self.deliver(.{ .transport_failure = completion.index });
                return;
            }
            switch (completion.operation) {
                .connect => switch (self.transport.connected(completion.index, completion.generation)) {
                    .success => self.deliver(.{ .connected = completion.index }),
                    .failure => |failure| {
                        self.transport.reportFailure(failure);
                        self.deliver(.{ .transport_failure = completion.index });
                    },
                },
                .send => {
                    if (completion.bytes != self.core.sessions[completion.index].attempt_bytes) {
                        self.deliver(.{ .transport_failure = completion.index });
                    } else {
                        self.deliver(.{ .sent = completion.index });
                    }
                },
                .receive => {
                    const expected = self.transport.expected(completion.index, self.core.sessions[completion.index].attempt_bytes);
                    if (expected.len != self.core.sessions[completion.index].attempt_bytes) self.transport.invariantFailure("client completion byte view");
                    const echoed = self.transport.received(completion.index, completion.generation, completion.bytes);
                    if (echoed.len != completion.bytes) self.transport.invariantFailure("client completion byte view");
                    self.deliver(.{ .received = .{ .index = completion.index, .echoed = echoed, .expected = expected } });
                },
                .generation_drained => unreachable,
            }
        }

        pub fn dispatch(self: *Self, actions: []const internal.worker.Action) void {
            var failed_session: ?u32 = null;
            for (actions) |action| {
                const index = switch (action) {
                    .connect, .close, .drain_timeout => |value| value,
                    .send => |value| value.index,
                    .receive => |value| value.index,
                };
                if (failed_session == index) continue;
                internal.worker.trace.eventArgs("STEP", "step={s}", .{@tagName(action)});
                const result = switch (action) {
                    .connect => self.transport.connect(index),
                    .send => |value| self.transport.send(index, value.bytes),
                    .receive => |value| self.transport.receive(index, value.bytes),
                    .close => self.transport.close(index),
                    .drain_timeout => self.transport.drainTimeout(index),
                };
                self.core.statistics.sent_bytes = self.transport.sentBytes();
                switch (result) {
                    .success => |posted| {
                        if (posted.posted_at) |at| {
                            switch (action) {
                                .connect => internal.session.scheduler.anchorPostedTimeout(self.core, index, at),
                                .close => internal.session.scheduler.anchorClose(self.core, index, at),
                                else => {},
                            }
                        }
                        if (posted.completion) |completion| self.handleCompletion(completion);
                    },
                    .failure => |failure| {
                        self.transport.reportFailure(failure);
                        failed_session = index;
                        self.deliver(.{ .transport_failure = index });
                    },
                }
            }
        }

        pub fn start(self: *Self) void {
            const region = self.core.acquireRegion();
            if (region.len == 0) return;
            defer self.core.releaseRegion();
            self.dispatch(internal.session.scheduler.start(self.core, self.clock.nowTicks(), region));
        }

        pub fn poll(self: *Self) void {
            // A due timer arbitrates only after every already-queued native operation could have
            // been acquired. The transport bounds this zero-wait drain by its ownership capacity.
            const now = self.clock.nowTicks();
            if (internal.session.scheduler.waitTicks(self.core, now, 1) == 0) self.transport.drainQueued(self);
            const region = self.core.acquireRegion();
            if (region.len == 0) return;
            defer self.core.releaseRegion();
            self.dispatch(internal.session.scheduler.poll(self.core, now, region));
        }

        pub fn run(self: *Self) void {
            if (self.owner) |owner| owner.phase = .running;
            self.start();
            self.transport.maybeArm();
            while (!internal.session.scheduler.allFinished(self.core) and !self.core.statistics.fatal) {
                const now = self.clock.nowTicks();
                if (self.owner) |owner| owner.publish(now, false);
                // Only the coordinator owns /w. A queued completion is consumed before stop and
                // deadline decisions, with a bounded drain so control cannot be starved.
                const maximum_ms: u64 = if (stopRequested()) 0 else maximum_wait_ms;
                const wait_ticks = internal.session.scheduler.waitTicks(self.core, now, self.clock.millisecondsToTicks(maximum_ms));
                const wait_ms: u32 = @intCast(@min(self.clock.ticksToWaitMilliseconds(wait_ticks), std.math.maxInt(u32)));
                self.transport.waitAndDrain(wait_ms, self);
                self.core.statistics.sent_bytes = self.transport.sentBytes();
                if (stopRequested() or self.core.stopping or self.core.statistics.fatal) break;
                self.poll();
                self.transport.maybeArm();
            }
            if (self.core.statistics.fatal) requestFatal();
            if (self.owner) |owner| owner.phase = .draining;
            self.shutdown();
            if (self.owner) |owner| {
                owner.publish(self.clock.nowTicks(), true);
                owner.phase = .stopped;
            }
        }

        pub fn shutdown(self: *Self) void {
            if (fatalRequested()) self.core.markFatal();
            internal.session.scheduler.beginShutdownAt(self.core, self.clock.nowTicks());
            if (self.owner) |owner| owner.publish(self.clock.nowTicks(), true);
            for (self.core.sessions) |entry| {
                const action = [_]internal.worker.Action{.{ .close = entry.index }};
                self.dispatch(&action);
            }
            // Each generation retains its first close deadline. Stop must not grant a second
            // grace period to a generation that was already cancelling before the stop arrived.
            while (self.transport.outstanding() != 0) {
                self.poll();
                if (self.transport.outstanding() == 0) break;
                const now = self.clock.nowTicks();
                const ticks = internal.session.scheduler.waitTicks(self.core, now, self.clock.millisecondsToTicks(50));
                const wait_ms: u32 = @intCast(@min(self.clock.ticksToWaitMilliseconds(ticks), 50));
                self.transport.waitAndDrain(wait_ms, self);
                self.core.statistics.sent_bytes = self.transport.sentBytes();
                if (self.owner) |owner| owner.publish(self.clock.nowTicks(), false);
                self.transport.maybeArm();
            }
            self.transport.retireNotifications();
        }
    };
}

/// Native transport specialization. It owns generation and request progress and never reads
/// business Session state. All provider accounting is retired before a Completion leaves here.
pub fn RioAdapter(comptime protocol: types.Protocol) type {
    return struct {
        const Self = @This();
        transport: *internal.worker.RioTransport,
        options: *const types.Options,
        clock: *native.clock.Clock,

        fn slotAt(self: *Self, index: u32) *native.transport.Slot {
            if (index >= self.transport.slots.len) native.diagnostics.failFast("client transport session index", c.ERROR_INVALID_DATA);
            return &self.transport.slots[index];
        }

        pub fn outstanding(self: *const Self) u32 {
            return self.transport.outstanding();
        }
        pub fn sentBytes(self: *const Self) u64 {
            return self.transport.sent_bytes;
        }

        pub fn reportFailure(_: *Self, failure: types.Failure) void {
            native.diagnostics.report(failure.stage, failure.native_code);
        }

        pub fn invariantFailure(_: *Self, stage: []const u8) noreturn {
            native.diagnostics.failFast(stage, c.ERROR_INVALID_DATA);
        }

        pub fn isLive(self: *Self, completion: internal.worker.Completion) bool {
            const slot = self.slotAt(completion.index);
            if (completion.generation != slot.generation) native.diagnostics.failFast("client completion generation", c.ERROR_INVALID_DATA);
            return !slot.closing;
        }

        fn drainCompletion(self: *Self, index: u32) ?internal.worker.Completion {
            const slot = self.slotAt(index);
            if (!slot.closing or !slot.drained() or slot.drain_reported) return null;
            slot.drain_reported = true;
            slot.send_posted_bytes = 0;
            slot.receive_posted_bytes = 0;
            slot.send_offset = 0;
            return .{ .index = index, .generation = slot.generation, .slot = native.completion.no_send_slot, .operation = .generation_drained, .status = 0, .bytes = 0 };
        }

        pub fn close(self: *Self, index: u32) PostResult {
            const slot = self.slotAt(index);
            const first_close = !slot.closing;
            const at: ?u64 = if (first_close) self.clock.nowTicks() else null;
            slot.closing = true;
            slot.close();
            return .{ .success = .{ .posted_at = at, .completion = self.drainCompletion(index) } };
        }

        pub fn drainTimeout(self: *Self, index: u32) PostResult {
            const slot = self.slotAt(index);
            if (!slot.drained()) native.diagnostics.failFast("client generation drain", c.ERROR_TIMEOUT);
            return .{ .success = .{ .completion = self.drainCompletion(index) } };
        }

        fn createRequestQueue(self: *Self, index: u32) types.Result(void) {
            const slot = self.slotAt(index);
            slot.request_queue = self.transport.api.?.createRq(slot.socket.value, 1, 1, 1, 1, self.transport.completion_queue.value, self.transport.completion_queue.value, @ptrCast(slot));
            if (slot.request_queue == c.RIO_INVALID_RQ) return .{ .failure = .{
                .stage = "RIOCreateRequestQueue(client)",
                .native_code = @bitCast(c.WSAGetLastError()),
                .domain = .winsock,
                .category = .connection,
            } };
            return .{ .success = {} };
        }

        pub fn connected(self: *Self, index: u32, generation: u32) types.Result(void) {
            const slot = self.slotAt(index);
            if (slot.generation != generation or slot.closing or slot.connect_outstanding) native.diagnostics.failFast("client connect completion ownership", c.ERROR_INVALID_DATA);
            if (protocol == .tcp) {
                switch (native.endpoint.updateConnectContextResult(slot.socket.value)) {
                    .success => {},
                    .failure => |failure| return .{ .failure = failure },
                }
                return self.createRequestQueue(index);
            }
            return .{ .success = {} };
        }

        pub fn connect(self: *Self, index: u32) PostResult {
            const slot = self.slotAt(index);
            slot.reset();
            slot.generation = native.completion.nextGeneration(slot.generation);
            slot.socket.reset(native.socket.registered(socketType(protocol), ipProtocol(protocol)));
            if (slot.socket.value == c.INVALID_SOCKET) return .{ .failure = .{
                .stage = "WSASocketW(client)",
                .native_code = @bitCast(c.WSAGetLastError()),
                .domain = .winsock,
                .category = .connection,
            } };
            switch (native.socket.configureResult(slot.socket.value, self.options.socket_buffer_bytes, protocol == .tcp)) {
                .success => {},
                .failure => |failure| return .{ .failure = failure },
            }
            switch (native.endpoint.bindLocalResult(slot.socket.value, self.options.local_port)) {
                .success => {},
                .failure => |failure| return .{ .failure = failure },
            }
            if (protocol == .udp) {
                switch (native.endpoint.connectUdpResult(slot.socket.value, &self.transport.remote_address)) {
                    .success => {},
                    .failure => |failure| return .{ .failure = failure },
                }
                switch (self.createRequestQueue(index)) {
                    .success => {},
                    .failure => |failure| return .{ .failure = failure },
                }
                return .{ .success = .{ .posted_at = self.clock.nowTicks(), .completion = .{
                    .index = index,
                    .generation = slot.generation,
                    .slot = native.completion.no_send_slot,
                    .operation = .connect,
                    .status = 0,
                    .bytes = 0,
                } } };
            }
            const socket_handle: c.HANDLE = @ptrFromInt(slot.socket.value);
            if (c.CreateIoCompletionPort(socket_handle, self.transport.port.get(), index + 1, 0) != self.transport.port.get()) return .{ .failure = .{
                .stage = "CreateIoCompletionPort(ConnectEx socket)",
                .native_code = c.GetLastError(),
                .domain = .win32,
                .category = .connection,
            } };
            slot.connect_overlapped = std.mem.zeroes(c.OVERLAPPED);
            slot.connect_outstanding = true;
            const at = self.clock.nowTicks();
            if (native.endpoint.beginConnect(self.transport.connect_ex.?, slot.socket.value, &self.transport.remote_address, &slot.connect_overlapped)) |code| {
                slot.connect_outstanding = false;
                return .{ .failure = .{ .stage = "ConnectEx", .native_code = @bitCast(code), .domain = .winsock, .category = .connection } };
            }
            return .{ .success = .{ .posted_at = at } };
        }

        fn sendTail(self: *Self, index: u32) types.Result(void) {
            const slot = self.slotAt(index);
            if (slot.closing or slot.send_outstanding != 0 or slot.send_offset >= slot.send_posted_bytes) native.diagnostics.failFast("client send posting ownership", c.ERROR_INVALID_DATA);
            const remaining = slot.send_posted_bytes - slot.send_offset;
            const context = native.completion.encode(index, slot.generation, native.completion.no_send_slot, .send) orelse
                native.diagnostics.failFast("client send context", c.ERROR_INVALID_DATA);
            var buffer = self.transport.arena.sendViewFrom(index, slot.send_offset, remaining) orelse
                native.diagnostics.failFast("client send window", c.ERROR_INVALID_DATA);
            if (!self.transport.api.?.send(slot.request_queue, &buffer, 0, context)) return .{ .failure = .{
                .stage = "RIOSend(client)",
                .native_code = @bitCast(c.WSAGetLastError()),
                .domain = .winsock,
                .category = .connection,
            } };
            slot.send_outstanding = 1;
            return .{ .success = {} };
        }

        pub fn send(self: *Self, index: u32, bytes: u32) PostResult {
            const slot = self.slotAt(index);
            if (slot.send_outstanding != 0 or slot.send_posted_bytes != 0 or bytes == 0) native.diagnostics.failFast("client send attempt ownership", c.ERROR_INVALID_DATA);
            slot.send_offset = 0;
            slot.send_posted_bytes = bytes;
            return switch (self.sendTail(index)) {
                .success => .{ .success = .{} },
                .failure => |failure| .{ .failure = failure },
            };
        }

        pub fn receive(self: *Self, index: u32, bytes: u32) PostResult {
            const slot = self.slotAt(index);
            if (slot.closing or slot.receive_outstanding != 0 or slot.receive_posted_bytes != 0 or bytes == 0) native.diagnostics.failFast("client receive posting ownership", c.ERROR_INVALID_DATA);
            const context = native.completion.encode(index, slot.generation, native.completion.no_send_slot, .receive) orelse
                native.diagnostics.failFast("client receive context", c.ERROR_INVALID_DATA);
            var buffer = self.transport.arena.receiveView(index, bytes) orelse
                native.diagnostics.failFast("client receive window", c.ERROR_INVALID_DATA);
            if (!self.transport.api.?.receive(slot.request_queue, &buffer, self.transport.receive_flags, context)) return .{ .failure = .{
                .stage = "RIOReceive(client)",
                .native_code = @bitCast(c.WSAGetLastError()),
                .domain = .winsock,
                .category = .connection,
            } };
            slot.receive_posted_bytes = bytes;
            slot.receive_outstanding = 1;
            return .{ .success = .{} };
        }

        pub fn expected(self: *Self, index: u32, bytes: usize) []const u8 {
            return self.transport.arena.sendBytes(index, @intCast(bytes)) orelse
                native.diagnostics.failFast("client send window", c.ERROR_INVALID_DATA);
        }

        pub fn received(self: *Self, index: u32, generation: u32, bytes: u32) []const u8 {
            const slot = self.slotAt(index);
            if (slot.generation != generation or slot.receive_outstanding != 0) native.diagnostics.failFast("client receive view ownership", c.ERROR_INVALID_DATA);
            if (bytes == 0) return &.{};
            return self.transport.arena.receiveBytes(index, bytes) orelse
                native.diagnostics.failFast("client receive window", c.ERROR_INVALID_DATA);
        }

        pub fn retireRio(self: *Self, result: c.RIORESULT) ?internal.worker.Completion {
            const context = result.RequestContext orelse native.diagnostics.failFast("client RIO RequestContext", c.ERROR_INVALID_DATA);
            const decoded = native.completion.decode(@intFromPtr(context)) orelse native.diagnostics.failFast("client RIO RequestContext", c.ERROR_INVALID_DATA);
            const slot = self.slotAt(decoded.index);
            // No old generation may retain ownership when a new one is created. A mismatched
            // record is corruption, not permission to decrement the current generation's ledger.
            if (decoded.generation != slot.generation or decoded.slot != native.completion.no_send_slot) native.diagnostics.failFast("client RIO completion ownership", c.ERROR_INVALID_DATA);
            var status = result.Status;
            var bytes = result.BytesTransferred;
            switch (decoded.operation) {
                .send => {
                    if (slot.send_outstanding != 1 or slot.send_posted_bytes == 0 or slot.send_offset >= slot.send_posted_bytes) native.diagnostics.failFast("client send completion accounting", c.ERROR_INVALID_DATA);
                    const remaining = slot.send_posted_bytes - slot.send_offset;
                    if (bytes > remaining) native.diagnostics.failFast("client completion exceeds posted range", c.ERROR_INVALID_DATA);
                    slot.send_outstanding = 0;
                    if (!slot.closing and status == 0) {
                        if (bytes == 0) {
                            status = native.completion.wsa_econnreset;
                        } else {
                            self.transport.sent_bytes +|= bytes;
                            slot.send_offset += bytes;
                            if (slot.send_offset < slot.send_posted_bytes) {
                                switch (self.sendTail(decoded.index)) {
                                    .success => return null,
                                    .failure => |failure| {
                                        native.diagnostics.report(failure.stage, failure.native_code);
                                        status = @bitCast(failure.native_code);
                                    },
                                }
                            }
                        }
                    }
                    bytes = slot.send_offset;
                    slot.send_posted_bytes = 0;
                    slot.send_offset = 0;
                },
                .receive => {
                    if (slot.receive_outstanding != 1 or slot.receive_posted_bytes == 0) native.diagnostics.failFast("client receive completion accounting", c.ERROR_INVALID_DATA);
                    if (bytes > slot.receive_posted_bytes) native.diagnostics.failFast("client completion exceeds posted range", c.ERROR_INVALID_DATA);
                    slot.receive_outstanding = 0;
                    slot.receive_posted_bytes = 0;
                },
                .connect, .generation_drained => native.diagnostics.failFast("client RIO completion operation", c.ERROR_INVALID_DATA),
            }
            if (slot.closing) return self.drainCompletion(decoded.index);
            return .{ .index = decoded.index, .generation = decoded.generation, .slot = decoded.slot, .operation = decoded.operation, .status = status, .bytes = bytes };
        }

        fn retireConnect(self: *Self, index: u32, ok: bool, native_error: u32) ?internal.worker.Completion {
            const slot = self.slotAt(index);
            if (!slot.connect_outstanding) native.diagnostics.failFast("ConnectEx outstanding count", c.ERROR_INVALID_DATA);
            slot.connect_outstanding = false;
            if (slot.closing) return self.drainCompletion(index);
            if (!ok) native.diagnostics.report("ConnectEx completion", native_error);
            return .{ .index = index, .generation = slot.generation, .slot = native.completion.no_send_slot, .operation = .connect, .status = if (ok) 0 else @bitCast(native_error), .bytes = 0 };
        }

        pub fn drain(self: *Self, budget: u32, runtime: anytype) void {
            var results: [completion_batch]c.RIORESULT = undefined;
            var batches: u32 = 0;
            while (batches < budget) : (batches += 1) {
                const count = requireDequeueCount(self.transport.api.?.dequeue(self.transport.completion_queue.value, &results, completion_batch), completion_batch);
                if (count == 0) return;
                for (results[0..count]) |result| {
                    if (self.retireRio(result)) |completion| runtime.handleCompletion(completion);
                }
            }
        }

        pub fn maybeArm(self: *Self) void {
            if (self.transport.completion_queue.armed) return;
            var rio_outstanding: u32 = 0;
            for (self.transport.slots) |slot| rio_outstanding += slot.send_outstanding + slot.receive_outstanding;
            if (rio_outstanding == 0) return;
            requireNotifySuccess(self.transport.api.?.notify(self.transport.completion_queue.value));
            requireNotificationRearmed(&self.transport.completion_queue.armed);
            self.transport.notification_arms +|= 1;
        }

        pub fn waitAndDrain(self: *Self, wait_ms: u32, runtime: anytype) void {
            _ = self.consumePacket(wait_ms, runtime);
            self.drain(drain_batches, runtime);
        }

        /// Each slot owns at most one ConnectEx packet or two RIO operations; notification and
        /// stop contribute at most one packet each. This finite zero-wait pass covers the complete
        /// ownership capacity before a due drain timer can declare a provider timeout.
        pub fn drainQueued(self: *Self, runtime: anytype) void {
            const packet_budget = self.transport.slots.len + 2;
            var packets: usize = 0;
            while (packets < packet_budget) : (packets += 1) {
                if (!self.consumePacket(0, runtime)) break;
            }
            // Count records instead of assuming full batches. New live posts must not turn this
            // deadline pass into more than the fixed ownership capacity worth of completions.
            const rio_budget: u32 = @intCast(self.transport.slots.len * 2);
            self.drainRecords(rio_budget, runtime);
        }

        fn drainRecords(self: *Self, budget: u32, runtime: anytype) void {
            var results: [completion_batch]c.RIORESULT = undefined;
            var remaining = budget;
            while (remaining != 0) {
                const requested = @min(completion_batch, remaining);
                const count = requireDequeueCount(self.transport.api.?.dequeue(self.transport.completion_queue.value, &results, requested), requested);
                if (count == 0) return;
                remaining -= count;
                for (results[0..count]) |result| {
                    if (self.retireRio(result)) |completion| runtime.handleCompletion(completion);
                }
            }
        }

        /// Acquires one IOCP packet. False means the zero/blocking wait found no packet; ownership
        /// and notification transitions are settled before the caller can process any timer.
        fn consumePacket(self: *Self, wait_ms: u32, runtime: anytype) bool {
            var transferred: c.DWORD = 0;
            var key: usize = 0;
            var overlapped: [*c]c.OVERLAPPED = null;
            const ok = c.GetQueuedCompletionStatus(self.transport.port.get(), &transferred, &key, &overlapped, wait_ms);
            const code: u32 = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS;
            if (overlapped == &self.transport.notification_overlapped) {
                if (ok == c.FALSE) native.diagnostics.failFast("GetQueuedCompletionStatus(client notification)", code);
                if (key != @intFromPtr(self.transport.notification_owner.?)) native.diagnostics.failFast("client RIO notification key", c.ERROR_INVALID_DATA);
                requireNotificationDelivered(&self.transport.completion_queue.armed);
                self.transport.notification_deliveries +|= 1;
            } else if (overlapped == null) {
                if (ok == c.FALSE) {
                    if (code != c.WAIT_TIMEOUT) native.diagnostics.failFast("GetQueuedCompletionStatus(client)", code);
                    if (self.outstanding() != 0) self.transport.timeout_wakeups_while_outstanding +|= 1;
                    return false;
                } else if (key != stop_key) {
                    native.diagnostics.failFast("unexpected client IOCP packet", c.ERROR_INVALID_DATA);
                }
            } else {
                if (key == 0 or key > self.transport.slots.len) native.diagnostics.failFast("unexpected ConnectEx completion key", c.ERROR_INVALID_DATA);
                const index: u32 = @intCast(key - 1);
                const slot = self.slotAt(index);
                if (overlapped != &slot.connect_overlapped) native.diagnostics.failFast("unexpected ConnectEx completion identity", c.ERROR_INVALID_DATA);
                if (transferred != 0) native.diagnostics.failFast("ConnectEx completion exceeds posted range", c.ERROR_INVALID_DATA);
                if (self.retireConnect(index, ok != c.FALSE, code)) |completion| runtime.handleCompletion(completion);
            }
            return true;
        }

        pub fn retireNotifications(self: *Self) void {
            // Drain only delivered packets on the worker thread. CQ and notification OVERLAPPED
            // stay alive until Worker.release after every worker has crossed the join barrier.
            if (self.outstanding() != 0) native.diagnostics.failFast("client CQ retirement with outstanding operations", c.ERROR_IO_INCOMPLETE);
            var transferred: c.DWORD = 0;
            var key: usize = 0;
            var overlapped: [*c]c.OVERLAPPED = null;
            var attempts: u32 = 0;
            while (attempts < iocp_retire_attempts) : (attempts += 1) {
                const ok = c.GetQueuedCompletionStatus(self.transport.port.get(), &transferred, &key, &overlapped, 0);
                if (ok == c.FALSE) {
                    const code = c.GetLastError();
                    if (overlapped != null or code != c.WAIT_TIMEOUT) native.diagnostics.failFast("GetQueuedCompletionStatus(client retirement)", code);
                    break;
                }
                if (overlapped == &self.transport.notification_overlapped) {
                    if (key != @intFromPtr(self.transport.notification_owner.?)) native.diagnostics.failFast("client RIO notification key", c.ERROR_INVALID_DATA);
                    requireNotificationDelivered(&self.transport.completion_queue.armed);
                    self.transport.notification_deliveries +|= 1;
                } else if (overlapped != null or key != stop_key) {
                    native.diagnostics.failFast("unexpected client retirement packet", c.ERROR_INVALID_DATA);
                }
                overlapped = null;
            }
        }
    };
}

fn nativeAdapter(comptime protocol: types.Protocol, wrk: *Worker) RioAdapter(protocol) {
    return .{ .transport = &wrk.transport, .options = wrk.core.options, .clock = &wrk.clock };
}

fn runWorker(comptime protocol: types.Protocol, wrk: *Worker) void {
    var transport = nativeAdapter(protocol, wrk);
    var runtime = WorkerRuntime(RioAdapter(protocol), native.clock.Clock){
        .core = &wrk.core,
        .transport = &transport,
        .clock = &wrk.clock,
        .owner = wrk,
    };
    runtime.run();
}

pub fn drainRio(comptime protocol: types.Protocol, wrk: *Worker, budget: u32) void {
    var transport = nativeAdapter(protocol, wrk);
    var runtime = WorkerRuntime(RioAdapter(protocol), native.clock.Clock){ .core = &wrk.core, .transport = &transport, .clock = &wrk.clock };
    transport.drain(budget, &runtime);
    wrk.core.statistics.sent_bytes = transport.sentBytes();
}

pub fn maybeArm(wrk: *Worker) void {
    var transport = nativeAdapter(.tcp, wrk);
    transport.maybeArm();
}

pub fn handleRioResult(comptime protocol: types.Protocol, wrk: *Worker, result: c.RIORESULT) void {
    var transport = nativeAdapter(protocol, wrk);
    var runtime = WorkerRuntime(RioAdapter(protocol), native.clock.Clock){ .core = &wrk.core, .transport = &transport, .clock = &wrk.clock };
    if (transport.retireRio(result)) |completion| runtime.handleCompletion(completion);
    wrk.core.statistics.sent_bytes = transport.sentBytes();
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
