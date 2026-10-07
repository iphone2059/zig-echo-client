const std = @import("std");
const win32 = @import("win32.zig");
const rio = @import("rio.zig");
const types = @import("types.zig");
const timer = @import("timer_heap.zig");
const bench_config = @import("bench_config");
const bench = @import("bench_histogram.zig");
const c = win32.c;

pub const WorkerPhase = enum(u8) { starting, running, draining, stopped };
pub const SessionState = enum(u8) { dormant, connecting, active, pacing, reconnecting, closing, done };
pub const Operation = enum(u8) { receive, send };

pub const WorkerLifecycle = struct {
    phase: WorkerPhase = .starting,
    live_sessions: u32 = 0,
    total_outstanding: u32 = 0,
    notification_armed: bool = false,
};

pub const Metrics = struct {
    claimed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    echoed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    corrupted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lost: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    network_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    latency_bins: [64]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
};

pub const WorkerResources = struct {
    port: win32.Handle = .{},
    thread: win32.ThreadHandle = .{},
    arena: win32.VirtualMemory = .{},
    registration: rio.Registration = .{},
    completion_queue: rio.CompletionQueue = .{},
    sessions: []Session = &.{},
    timer_nodes: []timer.Node = &.{},
    timer_positions: []u32 = &.{},
    session_sockets: []win32.Socket = &.{},

    pub fn deinit(self: *WorkerResources, allocator: std.mem.Allocator) void {
        for (self.session_sockets) |*socket| socket.deinit();
        self.completion_queue.deinit();
        self.registration.deinit();
        self.arena.deinit();
        if (self.session_sockets.len != 0) allocator.free(self.session_sockets);
        if (self.sessions.len != 0) allocator.free(self.sessions);
        if (self.timer_nodes.len != 0) allocator.free(self.timer_nodes);
        if (self.timer_positions.len != 0) allocator.free(self.timer_positions);
        self.port.deinit();
        self.* = .{};
    }
};

pub const Request = struct {
    session: ?*Session = null,
    operation: Operation = .receive,
};

pub const Session = struct {
    owner: ?*Worker = null,
    socket: c.SOCKET = c.INVALID_SOCKET,
    request_queue: c.RIO_RQ = c.RIO_INVALID_RQ,
    connect_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
    receive_request: Request = .{},
    send_request: Request = .{ .operation = .send },
    receive_buffer: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
    send_buffer: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
    state: SessionState = .dormant,
    index: u32 = 0,
    outstanding: u32 = 0,
    requested_echoes: u64 = 0,
    /// Echoes this session has already been granted, so the /n quota is spent per session.
    claimed: u64 = 0,
    attempt_bytes: usize = 0,
    send_offset: usize = 0,
    received_bytes: usize = 0,
    deadline: u64 = 0,
    next_action: u64 = 0,
    started_at: c.LARGE_INTEGER = .{ .QuadPart = 0 },
    send_done: bool = false,
    receive_done: bool = false,
    attempt_accounted: bool = false,
    reconnect_after_close: bool = false,
};

pub const Worker = struct {
    resources: ?*WorkerResources = null,
    rio_api: ?*const rio.Api = null,
    connect_ex: ?c.LPFN_CONNECTEX = null,
    options: ?*const types.Options = null,
    remote_address: ?*const c.SOCKADDR_IN = null,
    pattern: []const u8 = &.{},
    maximum_attempt_bytes: usize = 0,
    metrics: ?*Metrics = null,
    bench_histogram: if (bench_config.enabled) bench.Histogram else void = if (bench_config.enabled) bench.Histogram.init() else {},
    external_stop: ?*std.atomic.Value(bool) = null,
    fatal: ?*std.atomic.Value(bool) = null,
    port: c.HANDLE = null,
    thread: c.HANDLE = null,
    notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
    completion_queue: c.RIO_CQ = c.RIO_INVALID_CQ,
    registration: c.RIO_BUFFERID = c.RIO_INVALID_BUFFERID,
    memory: ?[*]u8 = null,
    sessions: ?[*]Session = null,
    timer_nodes: ?[*]timer.Node = null,
    timer_positions: ?[*]u32 = null,
    timers: ?timer.Heap = null,
    session_count: u32 = 0,
    worker_index: u32 = 0,
    live_sessions: u32 = 0,
    performance_frequency: c.LARGE_INTEGER = .{ .QuadPart = 0 },
    notification_armed: bool = false,
    stopping: bool = false,
    ready: bool = false,
};

pub fn workerMayRelease(lifecycle: *const WorkerLifecycle) bool {
    return lifecycle.phase == .stopped and lifecycle.live_sessions == 0 and lifecycle.total_outstanding == 0 and !lifecycle.notification_armed;
}

pub fn sessionTerminalAccountingValid(claimed: u64, echoed: u64, corrupted: u64, lost: u64) bool {
    return echoed <= claimed and corrupted <= claimed - echoed and lost == claimed - echoed - corrupted;
}

pub fn notificationPacketMatches(key: usize, overlapped: ?*c.OVERLAPPED, expected_key: usize, expected: ?*c.OVERLAPPED) bool {
    return key == expected_key and overlapped == expected;
}

fn pointerInSessions(candidate: *const Session, sessions: []const Session) bool {
    if (sessions.len == 0) return false;
    const start = @intFromPtr(sessions.ptr);
    const address = @intFromPtr(candidate);
    if (address < start) return false;
    const offset = address - start;
    return offset < sessions.len * @sizeOf(Session) and offset % @sizeOf(Session) == 0;
}

pub fn requestContextValid(request: *const Request, sessions: []const Session, owner: *const Worker) bool {
    const address = @intFromPtr(request);
    inline for (.{ "receive_request", "send_request" }) |field| {
        const offset = @offsetOf(Session, field);
        if (address >= offset) {
            const candidate: *const Session = @ptrFromInt(address - offset);
            if (pointerInSessions(candidate, sessions) and &@field(candidate, field) == request and candidate.owner == owner and request.session == candidate) return true;
        }
    }
    return false;
}

pub fn percentile(metrics: *const Metrics, total: u64, numerator: u64, denominator: u64) u64 {
    const target = @import("cec_contract.zig").percentileTarget(total, numerator, denominator);
    if (target == 0) return 0;
    var cumulative: u64 = 0;
    for (metrics.latency_bins, 0..) |bin, index| {
        cumulative += bin.load(.monotonic);
        if (cumulative >= target) return if (index == 63) std.math.maxInt(u64) else @as(u64, 1) << @intCast(index);
    }
    return @as(u64, 1) << 63;
}
