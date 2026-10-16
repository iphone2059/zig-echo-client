//! Shared client vocabulary: protocol, payload mode, exit codes, options and the capacities the
//! contract and the engine both budget against. Nothing here touches a native API, so every other
//! module in the project may depend on it without creating a cycle.
//!
//! Reference implementation: echo-binary-contract-v1 (the C++ client), mirrored by the Rust client.

const std = @import("std");

/// Identifier of the frozen binary contract this project implements.
pub const contract_version = "echo-binary-contract-v1";

pub const Protocol = enum(u8) { none = 0, tcp = 1, udp = 2 };

pub const PatternKind = enum(u8) {
    default_text = 0,
    literal_text = 1,
    binary_counter = 2,
    printable_counter = 3,
};

/// Process exit codes. The order is the binary contract's, not an implementation detail.
pub const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    network = 2,
    echo_failure = 3,
    internal = 4,
};

/// The phases a worker passes through, in order.
pub const WorkerPhase = enum(u8) { starting, running, draining, stopped };

/// The stop sequence a worker passes through, in order. A stop is published atomically, then
/// admission closes, cancellation is issued, the worker drains whatever the provider still owns,
/// and only then is it quiescent. One ordered phase replaces the booleans that used to imply each
/// other, so every reader asks the same question. Fatal stays a separate classification
/// (statistics.fatal), not a phase: a fatal run still walks the same sequence.
pub const ShutdownPhase = enum(u8) {
    /// Normal operation: attempts are admitted and run.
    running,
    /// A stop was applied: no new attempt may start and no reconnect is scheduled.
    admission_closed,
    /// Cancellation was issued for every live generation: sockets closed, drain deadlines armed.
    cancel_issued,
    /// Waiting for provider ownership to retire before this worker may leave.
    draining,
    /// Every generation retired; the worker may leave its loop and join.
    quiescent,
};

/// Copied after all workers join, before any native resources are released.
pub const NotifySnapshot = struct {
    worker: u32 = 0,
    arms: u64 = 0,
    deliveries: u64 = 0,
    timeout_wakeups: u64 = 0,

    pub fn writeLine(self: *const NotifySnapshot, protocol: Protocol, buffer: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buffer, "role=client protocol={s} worker={d} notify_arms={d} notify_deliveries={d} notify_gap={d} timeout_wakeups_while_outstanding={d}\n", .{ if (protocol == .tcp) "tcp" else "udp", self.worker, self.arms, self.deliveries, self.arms -| self.deliveries, self.timeout_wakeups }) catch null;
    }
};

/// Normalized operations and errors are shared values, independent of a native ABI.
pub const Operation = enum(u8) { connect = 1, send = 2, receive = 3, generation_drained = 4 };
pub const ErrorDomain = enum { win32, winsock, allocation, capacity, invariant };
pub const ErrorCategory = enum { initialization, connection, provider, invariant };
pub const Failure = struct {
    stage: []const u8,
    native_code: u32,
    domain: ErrorDomain,
    category: ErrorCategory = .initialization,
    retryable: bool = false,
};

pub fn Result(comptime T: type) type {
    return union(enum) { success: T, failure: Failure };
}

/// The session-count bound. The quota arithmetic refuses anything larger before a session exists.
pub const maximum_sessions: u32 = 1_048_576;

/// Automatic worker count is the active processor count clamped to this cap, mirroring the
/// reference's CEC_MAX_WORKERS.
pub const automatic_worker_cap: u32 = 64;

/// Command-line capacities. Both are measured in UTF-16 code units, exactly as the reference
/// measures them before the Windows command line is converted.
pub const host_capacity: usize = 256;
pub const literal_capacity: usize = 32_768;
pub const error_capacity: usize = 256;

pub const default_remote_port: u16 = 7;
pub const default_echo_count: u64 = 5;
pub const default_timeout_seconds: u32 = 5;
pub const default_cq_capacity: u32 = 4_096;
pub const default_memory_bytes: u64 = 1_073_741_824;

/// One attempt may not carry more than this many payload bytes, whatever the pipeline switch says.
pub const maximum_tcp_batch_bytes: u64 = 67_108_864;
/// One UDP datagram may not carry more than this many payload bytes.
pub const maximum_udp_payload: u64 = 65_507;

/// Overflow-checked arithmetic as a compile-time type generic: the compiler emits one concrete
/// copy per integer type actually used, so capacity budgets never pay for dynamic dispatch and can
/// never wrap into an apparently valid value.
pub fn checkedProduct(comptime T: type, left: T, right: T) ?T {
    const pair = @mulWithOverflow(left, right);
    return if (pair[1] == 0) pair[0] else null;
}

pub fn checkedAdd(comptime T: type, left: T, right: T) ?T {
    const pair = @addWithOverflow(left, right);
    return if (pair[1] == 0) pair[0] else null;
}

/// Ceiling division that cannot overflow, used by the clock conversions and the shard split.
pub fn ceilingDivide(comptime T: type, numerator: T, denominator: T) T {
    if (denominator == 0) return numerator;
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

/// Resolves the worker switch, or the automatic count when it is absent, exactly like the
/// reference: the processor count is clamped to [1, 64] and the caller then takes the smaller of
/// that and the session count. The processor count is passed in so the rule is testable without
/// the machine.
pub fn resolvedWorkerCount(worker_count: u32, processors: u32) u64 {
    if (worker_count != 0) return worker_count;
    return @min(@max(processors, 1), automatic_worker_cap);
}

pub const Options = struct {
    protocol: Protocol = .none,
    pattern_kind: PatternKind = .default_text,
    host: [host_capacity]u16 = @splat(0),
    host_len: u16 = 0,
    literal_pattern: [literal_capacity]u16 = @splat(0),
    literal_len: u16 = 0,
    remote_port: u16 = default_remote_port,
    local_port: u16 = 0,
    echo_count: u64 = default_echo_count,
    timeout_seconds: u32 = default_timeout_seconds,
    interval_milliseconds: u32 = 0,
    socket_buffer_bytes: u32 = 0,
    pipeline_depth: u32 = 1,
    pattern_bytes: u32 = 0,
    run_seconds: u32 = 0,
    /// None disables reconnects; Some(delay) reschedules a failed session once the old transport
    /// generation has completely drained.
    reconnect_seconds: ?u32 = null,
    report_seconds: u32 = 0,
    session_count: u32 = 1,
    worker_count: u32 = 0,
    cq_capacity: u32 = default_cq_capacity,
    memory_bytes: u64 = default_memory_bytes,
    quiet: bool = false,
    stats: bool = false,
    help: bool = false,

    pub fn hostUtf16(self: *const Options) []const u16 {
        return self.host[0..self.host_len];
    }

    pub fn literalUtf16(self: *const Options) []const u16 {
        return self.literal_pattern[0..self.literal_len];
    }

    pub fn hostUtf8(self: *const Options, buffer: []u8) ![]u8 {
        const needed = std.unicode.wtf16LeToWtf8(buffer, self.hostUtf16());
        if (needed > buffer.len) return error.NoSpaceLeft;
        return buffer[0..needed];
    }

    pub fn reconnectEnabled(self: *const Options) bool {
        return self.reconnect_seconds != null;
    }

    /// Echo units one attempt may carry: the pipeline depth for TCP and a single unit for UDP.
    pub fn batchCapacity(self: *const Options) u32 {
        return if (self.protocol == .tcp) @max(self.pipeline_depth, 1) else 1;
    }
};

test "worker resolution follows the reference" {
    try std.testing.expectEqual(@as(u64, 7), resolvedWorkerCount(7, 32));
    try std.testing.expectEqual(@as(u64, 32), resolvedWorkerCount(0, 32));
    try std.testing.expectEqual(@as(u64, 1), resolvedWorkerCount(0, 0));
    try std.testing.expectEqual(@as(u64, 64), resolvedWorkerCount(0, 128));
}

test "notification snapshots preserve the shared diagnostic schema" {
    var buffer: [256]u8 = undefined;
    var snapshot = NotifySnapshot{ .worker = 3, .arms = 7, .deliveries = 6, .timeout_wakeups = 2 };
    const tcp = snapshot.writeLine(.tcp, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("role=client protocol=tcp worker=3 notify_arms=7 notify_deliveries=6 notify_gap=1 timeout_wakeups_while_outstanding=2\n", tcp);
    snapshot.deliveries = 8;
    const udp = snapshot.writeLine(.udp, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("role=client protocol=udp worker=3 notify_arms=7 notify_deliveries=8 notify_gap=0 timeout_wakeups_while_outstanding=2\n", udp);
    try std.testing.expect(snapshot.writeLine(.tcp, buffer[0..8]) == null);
}

test "capacity arithmetic is checked" {
    try std.testing.expectEqual(@as(?u64, 800), checkedProduct(u64, 8, 100));
    try std.testing.expectEqual(@as(?u64, null), checkedProduct(u64, std.math.maxInt(u64), 2));
    try std.testing.expectEqual(@as(u64, 4), ceilingDivide(u64, 7, 2));
    try std.testing.expectEqual(@as(u64, 3), ceilingDivide(u64, 6, 2));
}
