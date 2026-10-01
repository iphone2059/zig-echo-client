const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const rio = @import("rio.zig");
const contract = @import("contract.zig");
const pattern_mod = @import("pattern.zig");
const types = @import("types.zig");
const internal = @import("engine_internal.zig");
const bench_config = @import("bench_config");
const session_machine = @import("client_session.zig");
const worker_machine = @import("client_worker.zig");

pub const Worker = internal.Worker;
pub const Session = internal.Session;
pub const Metrics = internal.Metrics;
const allocator = std.heap.page_allocator;

pub const WorkerResources = internal.WorkerResources;

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

pub const requireNotifySuccess = worker_machine.requireNotifySuccess;
pub const requireDequeueCount = worker_machine.requireDequeueCount;
pub const requireNotificationDelivered = worker_machine.requireNotificationDelivered;
pub const requireNotificationRearmed = worker_machine.requireNotificationRearmed;
pub const requireControlPost = worker_machine.requireControlPost;

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

pub const retireCompletionQueue = worker_machine.retireCompletionQueue;
pub const initializeWorker = worker_machine.initializeWorker;
pub const startWorker = worker_machine.startWorker;
pub const postWorkerStop = worker_machine.postWorkerStop;
pub const joinWorker = worker_machine.joinWorker;
pub const destroyWorker = worker_machine.destroyWorker;

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
        initializeWorker(&workers[initialized], &extensions, options, &remote, pattern, maximum_attempt_bytes, &metrics, stop, &fatal, initialized, sessions, share, &owners[initialized]) catch {
            fatal.store(true, .release);
            break;
        };
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
