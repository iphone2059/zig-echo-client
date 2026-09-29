const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const rio_mod = @import("rio.zig");
const contract = @import("contract.zig");
const timer = @import("timer_heap.zig");
const pattern_mod = @import("pattern.zig");
const types = @import("types.zig");

const batch_size: u32 = 256;
const Op = enum(u8) { receive, send };
const State = enum(u8) { starting, active, pacing, closing, done };

const Request = struct { session: *Session, op: Op };
const Session = struct {
    socket: c.SOCKET = c.INVALID_SOCKET,
    rq: c.RIO_RQ = c.RIO_INVALID_RQ,
    receive_request: Request = undefined,
    send_request: Request = undefined,
    receive_buffer: c.RIO_BUF = undefined,
    send_buffer: c.RIO_BUF = undefined,
    state: State = .starting,
    index: u32 = 0,
    outstanding: u32 = 0,
    send_offset: usize = 0,
    received_bytes: usize = 0,
    deadline: u64 = 0,
    started_at: c.LARGE_INTEGER = undefined,
    send_done: bool = false,
    receive_done: bool = false,
};

const Metrics = struct {
    claimed: u64 = 0,
    echoed: u64 = 0,
    corrupted: u64 = 0,
    lost: u64 = 0,
    bytes: u64 = 0,
    network_errors: u64 = 0,
    latency_bins: [64]u64 = @splat(0),
    max_us: u64 = 0,
};

fn resolveIpv4(allocator: std.mem.Allocator, host: []const u8, port: u16, remote: *c.SOCKADDR_IN) bool {
    const host_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, host) catch return false;
    defer allocator.free(host_w);
    var service_buf: [16]u8 = undefined;
    const service = std.fmt.bufPrint(&service_buf, "{d}", .{port}) catch return false;
    const service_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, service) catch return false;
    defer allocator.free(service_w);
    var hints: c.ADDRINFOW = std.mem.zeroes(c.ADDRINFOW);
    hints.ai_family = c.AF_INET;
    var results: [*c]c.ADDRINFOW = null;
    const status = c.GetAddrInfoW(host_w.ptr, service_w.ptr, &hints, &results);
    if (status != 0 or results == null) {
        win32.report("GetAddrInfoW(IPv4)", @intCast(status));
        return false;
    }
    defer c.FreeAddrInfoW(results);
    const addr: *const c.SOCKADDR_IN = @ptrCast(@alignCast(results.*.ai_addr));
    remote.* = addr.*;
    return true;
}

fn buildPattern(allocator: std.mem.Allocator, options: *const types.Options) ?[]u8 {
    if (options.pattern_kind == .binary_counter or options.pattern_kind == .printable_counter) {
        const out = allocator.alloc(u8, options.pattern_bytes) catch return null;
        if (options.pattern_kind == .binary_counter) pattern_mod.fillBinary(out) else pattern_mod.fillPrintable(out);
        return out;
    }
    if (options.pattern_kind == .literal_text) return allocator.dupe(u8, options.literal_pattern) catch null;
    const out = std.fmt.allocPrint(allocator, "C++ echo from {s}", .{options.host}) catch return null;
    return out;
}

fn latencyBin(us: u64) usize {
    var value = @max(us, 1);
    var bin: usize = 0;
    while (value > 1 and bin < 63) : (bin += 1) value >>= 1;
    return bin;
}

fn recordLatency(metrics: *Metrics, start: c.LARGE_INTEGER, frequency: c.LARGE_INTEGER) void {
    var finish: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceCounter(&finish) == c.FALSE or frequency.QuadPart <= 0) return;
    const ticks: u64 = @intCast(@max(@as(i64, 0), finish.QuadPart - start.QuadPart));
    const freq: u64 = @intCast(frequency.QuadPart);
    const scaled: u128 = @as(u128, ticks) * 1_000_000;
    const us128: u128 = scaled / freq;
    const capped: u128 = @min(us128, @as(u128, std.math.maxInt(u64)));
    const us: u64 = @max(@as(u64, 1), @as(u64, @intCast(capped)));
    metrics.latency_bins[latencyBin(us)] += 1;
    metrics.max_us = @max(metrics.max_us, us);
}

fn arm(api: *const rio_mod.Api, cq: c.RIO_CQ, overlapped: *c.OVERLAPPED, armed: *bool) void {
    if (armed.*) win32.failFast("duplicate client RIONotify", c.ERROR_INVALID_STATE);
    overlapped.* = std.mem.zeroes(c.OVERLAPPED);
    const status = api.notify(cq);
    if (status != c.ERROR_SUCCESS) win32.failFast("RIONotify(client)", @intCast(status));
    if (!contract.notificationMarkRearmed(armed)) win32.failFast("client notification rearm transition", c.ERROR_INVALID_STATE);
}

fn closeSocket(session: *Session) void {
    if (session.socket != c.INVALID_SOCKET) {
        _ = c.closesocket(session.socket);
        session.socket = c.INVALID_SOCKET;
    }
}

fn schedule(heap: *timer.Heap, s: *Session, deadline: u64) void {
    s.deadline = deadline;
    if (!heap.insertOrUpdate(s.index, deadline)) win32.failFast("client timer insert/update", c.ERROR_INVALID_DATA);
}

fn unschedule(heap: *timer.Heap, s: *Session) void { _ = heap.remove(s.index); }

fn markDone(heap: *timer.Heap, s: *Session, live: *u32) void {
    if (s.state != .done) {
        unschedule(heap, s);
        closeSocket(s);
        s.state = .done;
        live.* -= 1;
    }
}

fn closeOrDrain(heap: *timer.Heap, s: *Session, live: *u32) void {
    unschedule(heap, s);
    closeSocket(s);
    if (s.outstanding == 0) {
        markDone(heap, s, live);
    } else {
        s.state = .closing;
    }
}

fn postReceive(api: *const rio_mod.Api, s: *Session, pattern_bytes: usize, max_attempt: usize) bool {
    s.receive_buffer.Offset = @intCast(@as(usize, s.index) * 2 * max_attempt + max_attempt);
    s.receive_buffer.Length = @intCast(pattern_bytes);
    if (!api.receive(s.rq, &s.receive_buffer, 0, @ptrCast(&s.receive_request))) return false;
    s.outstanding += 1;
    return true;
}

fn postSend(api: *const rio_mod.Api, s: *Session, pattern_bytes: usize, max_attempt: usize) bool {
    s.send_buffer.Offset = @intCast(@as(usize, s.index) * 2 * max_attempt + s.send_offset);
    s.send_buffer.Length = @intCast(pattern_bytes - s.send_offset);
    if (!api.send(s.rq, &s.send_buffer, 0, @ptrCast(&s.send_request))) return false;
    s.outstanding += 1;
    return true;
}

fn beginAttempt(api: *const rio_mod.Api, heap: *timer.Heap, s: *Session, options: *const types.Options, metrics: *Metrics, pattern_bytes: usize, max_attempt: usize, live: *u32) bool {
    if (contract.claimAttempts(&metrics.claimed, options.echo_count, 1) == 0) {
        markDone(heap, s, live);
        return true;
    }
    s.send_offset = 0;
    s.received_bytes = 0;
    s.send_done = false;
    s.receive_done = false;
    s.state = .active;
    _ = c.QueryPerformanceCounter(&s.started_at);
    schedule(heap, s, c.GetTickCount64() + @as(u64, options.timeout_seconds) * 1000);
    if (!postReceive(api, s, pattern_bytes, max_attempt)) return false;
    if (!postSend(api, s, pattern_bytes, max_attempt)) return false;
    return true;
}

fn completeAttempt(api: *const rio_mod.Api, heap: *timer.Heap, s: *Session, options: *const types.Options, metrics: *Metrics, memory: [*]u8, pattern_bytes: usize, max_attempt: usize, frequency: c.LARGE_INTEGER, live: *u32) bool {
    if (!s.send_done or !s.receive_done or s.outstanding != 0) return true;
    const base = @as(usize, s.index) * 2 * max_attempt;
    const sent = memory[base .. base + pattern_bytes];
    const received = memory[base + max_attempt .. base + max_attempt + s.received_bytes];
    recordLatency(metrics, s.started_at, frequency);
    if (s.received_bytes == pattern_bytes and std.mem.eql(u8, sent, received)) {
        metrics.echoed += 1;
        metrics.bytes += pattern_bytes;
    } else metrics.corrupted += 1;
    unschedule(heap, s);
    if (options.interval_milliseconds != 0) {
        s.state = .pacing;
        schedule(heap, s, c.GetTickCount64() + options.interval_milliseconds);
        return true;
    }
    return beginAttempt(api, heap, s, options, metrics, pattern_bytes, max_attempt, live);
}

fn percentile(metrics: *const Metrics, total: u64, numerator: u64, denominator: u64) u64 {
    const target = contract.percentileTarget(total, numerator, denominator);
    if (target == 0) return 0;
    var cumulative: u64 = 0;
    for (metrics.latency_bins, 0..) |count, i| {
        cumulative += count;
        if (cumulative >= target) return @as(u64, 1) << @intCast(i);
    }
    return metrics.max_us;
}

fn printMetrics(label: []const u8, options: *const types.Options, metrics: *const Metrics, elapsed_ms: u64) void {
    const elapsed = @max(@as(u64, 1), elapsed_ms);
    var samples: u64 = 0;
    for (metrics.latency_bins) |value| samples += value;
    const echo_per_sec = (@as(f64, @floatFromInt(metrics.echoed)) * 1000.0) / @as(f64, @floatFromInt(elapsed));
    const mib_per_sec = (@as(f64, @floatFromInt(metrics.bytes)) * 1000.0) /
        (@as(f64, @floatFromInt(elapsed)) * 1024.0 * 1024.0);
    std.debug.print(
        "{s} protocol=udp elapsed_ms={d} sessions={d} claimed={d} echoed={d} corrupted={d} lost={d} network_errors={d} " ++
            "echo_per_sec={d:.2} MiB_per_sec={d:.2} p50_us~={d} p99_us~={d} p999_us~={d} max_us~={d} latency_samples={d}\n",
        .{
            label,
            elapsed_ms,
            options.session_count,
            metrics.claimed,
            metrics.echoed,
            metrics.corrupted,
            metrics.lost,
            metrics.network_errors,
            echo_per_sec,
            mib_per_sec,
            percentile(metrics, samples, 50, 100),
            percentile(metrics, samples, 99, 100),
            percentile(metrics, samples, 999, 1000),
            metrics.max_us,
            samples,
        },
    );
}

pub fn run(api: *const rio_mod.Api, options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
    const allocator = std.heap.page_allocator;
    var remote: c.SOCKADDR_IN = undefined;
    if (!resolveIpv4(allocator, options.host, options.remote_port, &remote)) return .network;
    const pattern = buildPattern(allocator, options) orelse return .network;
    defer allocator.free(pattern);
    if (pattern.len == 0 or pattern.len > types.maximum_udp_payload) return .usage;
    const max_attempt = pattern.len;
    const arena_bytes = contract.checkedStorageBytes(options.session_count, max_attempt, options.memory_bytes) orelse return .network;
    if (arena_bytes > std.math.maxInt(u32) or options.cq_capacity < options.session_count * 2) return .network;
    if (options.worker_count > 1 or options.reconnect_seconds >= 0) {
        std.debug.print("This first UDP code slice currently uses one CQ/IOCP worker and does not enable /rc; /threads >1 and /rc are reserved for the full parity port.\n", .{});
        return .usage;
    }

    var frequency: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceFrequency(&frequency) == c.FALSE or frequency.QuadPart <= 0) return .internal;
    var port = win32.Handle{ .value = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1) };
    defer port.deinit();
    if (port.value == null) return .network;
    var memory = win32.VirtualMemory.alloc(arena_bytes) catch return .network;
    defer memory.deinit();
    var registration = rio_mod.Registration{ .api = api, .id = api.registerBuffer(memory.bytes(), @intCast(arena_bytes)) };
    defer registration.deinit();
    if (registration.id == c.RIO_INVALID_BUFFERID) return .network;

    const sessions = allocator.alloc(Session, options.session_count) catch return .network;
    defer allocator.free(sessions);
    const nodes = allocator.alloc(timer.Node, options.session_count) catch return .network;
    defer allocator.free(nodes);
    const positions = allocator.alloc(u32, options.session_count) catch return .network;
    defer allocator.free(positions);
    var timers = timer.Heap.init(nodes, positions) catch return .internal;

    for (sessions, 0..) |*s, i| {
        s.* = .{ .index = @intCast(i) };
        s.receive_request = .{ .session = s, .op = .receive };
        s.send_request = .{ .session = s, .op = .send };
        s.receive_buffer.BufferId = registration.id;
        s.send_buffer.BufferId = registration.id;
        const base = i * 2 * max_attempt;
        pattern_mod.fillRepeated(memory.bytes()[base .. base + max_attempt], pattern);
    }

    var notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = port.value;
    notification.Iocp.CompletionKey = @ptrCast(sessions.ptr);
    notification.Iocp.Overlapped = &notification_overlapped;
    var cq = rio_mod.CompletionQueue{ .api = api, .value = api.createCq(options.cq_capacity, &notification) };
    defer cq.deinit();
    if (cq.value == c.RIO_INVALID_CQ) return .network;

    var metrics: Metrics = .{};
    var live: u32 = options.session_count;
    for (sessions) |*s| {
        s.socket = win32.registeredSocket(c.SOCK_DGRAM, c.IPPROTO_UDP);
        if (s.socket == c.INVALID_SOCKET or !win32.configureSocket(s.socket, options.socket_buffer_bytes, false)) {
            metrics.network_errors += 1; markDone(&timers, s, &live); continue;
        }
        var local: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
        local.sin_family = c.AF_INET;
        local.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
        local.sin_port = c.htons(options.local_port);
        if (c.bind(s.socket, @ptrCast(&local), @intCast(@sizeOf(c.SOCKADDR_IN))) != 0 or
            c.connect(s.socket, @ptrCast(&remote), @intCast(@sizeOf(c.SOCKADDR_IN))) != 0)
        {
            metrics.network_errors += 1; markDone(&timers, s, &live); continue;
        }
        s.rq = api.createRq(s.socket, 1, 1, 1, 1, cq.value, cq.value, @ptrCast(s));
        if (s.rq == c.RIO_INVALID_RQ) {
            metrics.network_errors += 1;
            markDone(&timers, s, &live);
            continue;
        }
        if (!beginAttempt(api, &timers, s, options, &metrics, pattern.len, max_attempt, &live)) {
            metrics.network_errors += 1;
            metrics.lost += 1;
            closeOrDrain(&timers, s, &live);
            continue;
        }
    }

    var armed = false;
    if (live != 0) arm(api, cq.value, &notification_overlapped, &armed);
    const start = c.GetTickCount64();
    var next_report: u64 = if (options.report_seconds == 0)
        std.math.maxInt(u64)
    else
        start + @as(u64, options.report_seconds) * 1000;
    var results: [batch_size]c.RIORESULT = undefined;
    var stopping = false;

    while (live != 0) {
        if (!stopping and (stop.load(.acquire) or (options.run_seconds != 0 and c.GetTickCount64() - start >= @as(u64, options.run_seconds) * 1000))) {
            stopping = true;
            for (sessions) |*s| if (s.state != .done) {
                closeOrDrain(&timers, s, &live);
            };
        }

        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const wait_ms = timers.waitMilliseconds(c.GetTickCount64());
        const ok = c.GetQueuedCompletionStatus(port.value, &transferred, &key, &overlapped, wait_ms);
        const err: u32 = if (ok == c.FALSE) @intCast(c.GetLastError()) else c.ERROR_SUCCESS;
        if (overlapped == &notification_overlapped) {
            if (ok == c.FALSE or key != @intFromPtr(sessions.ptr)) win32.failFast("client notification packet", err);
            if (!contract.notificationMarkDelivered(&armed)) win32.failFast("client notification delivery transition", c.ERROR_INVALID_STATE);
            while (true) {
                const count = api.dequeue(cq.value, &results, batch_size);
                if (count == c.RIO_CORRUPT_CQ) win32.failFast("RIODequeueCompletion(client)", c.ERROR_INVALID_DATA);
                if (count == 0) break;
                for (results[0..count]) |result| {
                    const raw = result.RequestContext orelse win32.failFast("client null RequestContext", c.ERROR_INVALID_DATA);
                    const req: *Request = @ptrCast(@alignCast(raw));
                    const s = req.session;
                    if (s.outstanding == 0) win32.failFast("client RIO outstanding count", c.ERROR_INVALID_DATA);
                    s.outstanding -= 1;
                    if (s.state == .closing) {
                        if (s.outstanding == 0) markDone(&timers, s, &live);
                        continue;
                    }
                    if (result.Status != c.ERROR_SUCCESS) {
                        metrics.lost += 1;
                        metrics.network_errors += 1;
                        closeOrDrain(&timers, s, &live);
                        continue;
                    }
                    if (req.op == .send) {
                        if (result.BytesTransferred == 0 or result.BytesTransferred > pattern.len - s.send_offset) {
                            metrics.lost += 1;
                            metrics.network_errors += 1;
                            closeOrDrain(&timers, s, &live);
                            continue;
                        }
                        s.send_offset += result.BytesTransferred;
                        if (s.send_offset < pattern.len) {
                            if (!postSend(api, s, pattern.len, max_attempt)) {
                                metrics.lost += 1;
                                metrics.network_errors += 1;
                                closeOrDrain(&timers, s, &live);
                            }
                            continue;
                        }
                        s.send_done = true;
                    } else {
                        s.received_bytes = result.BytesTransferred;
                        s.receive_done = true;
                    }
                    if (!completeAttempt(api, &timers, s, options, &metrics, memory.bytes(), pattern.len, max_attempt, frequency, &live)) {
                        metrics.lost += 1;
                        metrics.network_errors += 1;
                        closeOrDrain(&timers, s, &live);
                    }
                }
            }
            if (live != 0) arm(api, cq.value, &notification_overlapped, &armed);
        } else if (ok == c.FALSE and err != c.WAIT_TIMEOUT) {
            win32.failFast("GetQueuedCompletionStatus(client)", err);
        } else if (!(ok == c.FALSE and err == c.WAIT_TIMEOUT and overlapped == null)) {
            win32.failFast("unexpected client IOCP packet", c.ERROR_INVALID_DATA);
        }

        const now = c.GetTickCount64();
        while (timers.popExpired(now)) |idx| {
            const s = &sessions[idx];
            if (s.state == .pacing) {
                if (!beginAttempt(api, &timers, s, options, &metrics, pattern.len, max_attempt, &live)) {
                    metrics.network_errors += 1;
                    metrics.lost += 1;
                    closeOrDrain(&timers, s, &live);
                }
            } else if (s.state == .active) {
                metrics.network_errors += 1;
                metrics.lost += 1;
                closeOrDrain(&timers, s, &live);
            }
        }
        if (now >= next_report) {
            printMetrics("report", options, &metrics, now - start);
            next_report = now + @as(u64, options.report_seconds) * 1000;
        }
    }

    if (armed) {
        if (c.PostQueuedCompletionStatus(port.value, 0, 0, &notification_overlapped) == c.FALSE)
            win32.failFast("PostQueuedCompletionStatus(client notification shutdown)", @intCast(c.GetLastError()));
        var transferred: c.DWORD = 0; var key: c.ULONG_PTR = 0; var overlapped: [*c]c.OVERLAPPED = null;
        if (c.GetQueuedCompletionStatus(port.value, &transferred, &key, &overlapped, 1000) == c.FALSE)
            win32.failFast("GetQueuedCompletionStatus(client notification shutdown)", @intCast(c.GetLastError()));
        if (key != 0 or overlapped != &notification_overlapped) win32.failFast("client notification shutdown packet", c.ERROR_INVALID_DATA);
        if (!contract.notificationMarkDelivered(&armed)) win32.failFast("client notification shutdown transition", c.ERROR_INVALID_STATE);
    }
    for (sessions) |*s| closeSocket(s);

    const never_claimed = contract.unclaimedEchoes(options.echo_count, metrics.claimed, stopping);
    metrics.lost += never_claimed;
    const elapsed = c.GetTickCount64() - start;
    if (!options.quiet or options.stats) printMetrics("final", options, &metrics, elapsed);

    return @enumFromInt(contract.classifyResult(
        metrics.echoed,
        metrics.corrupted,
        metrics.lost,
        metrics.network_errors,
        false,
        stopping,
    ));
}
