//! The client binary's contract, in one place: the command line (switches, ranges, diagnostic
//! tokens, usage text) and the contract helpers the engine needs, mirroring the reference's single
//! contract file.
//!
//! Reference implementation: echo-binary-contract-v1 (the C++ client).

/// Identifier of the frozen binary contract this file implements.
pub const version = "echo-binary-contract-v1";

/// The value switches this client accepts, as compile-time data. The parser asks the table instead
/// of spelling every switch name out at each use, so the accepted set lives in exactly one place.
/// Which protocol a switch belongs to; the parser rejects a switch used with the wrong one.
pub const Scope = enum { both, tcp_only, udp_only };

pub const Switch = struct {
    name: []const u8,
    minimum: u64,
    maximum: u64,
    scope: Scope,
};

pub const switch_table = [_]Switch{
    .{ .name = "p", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "r", .minimum = 1, .maximum = 65535, .scope = .both },
    .{ .name = "l", .minimum = 0, .maximum = 65535, .scope = .both },
    .{ .name = "n", .minimum = 0, .maximum = std.math.maxInt(u64), .scope = .both },
    .{ .name = "t", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "i", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "d", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "z", .minimum = 1, .maximum = types.maximum_tcp_batch_bytes, .scope = .both },
    .{ .name = "zt", .minimum = 1, .maximum = types.maximum_tcp_batch_bytes, .scope = .both },
    .{ .name = "k", .minimum = 1, .maximum = 65536, .scope = .tcp_only },
    .{ .name = "c", .minimum = 1, .maximum = 1048576, .scope = .both },
    .{ .name = "threads", .minimum = 1, .maximum = 64, .scope = .both },
    .{ .name = "w", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "rc", .minimum = 0, .maximum = std.math.maxInt(i32), .scope = .both },
    .{ .name = "report", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "b", .minimum = 0, .maximum = std.math.maxInt(i32), .scope = .both },
    .{ .name = "cq", .minimum = 64, .maximum = 1048576, .scope = .both },
    .{ .name = "memory", .minimum = 1048576, .maximum = std.math.maxInt(u64), .scope = .both },
};

comptime {
    if (switchInfo("k").?.scope != .tcp_only) @compileError("switch k must stay TCP only");
}
/// Compile-time lookup: the table is unrolled by the compiler, so a typo here is a build error.
pub fn switchInfo(name: []const u8) ?Switch {
    inline for (switch_table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry;
    }
    return null;
}


/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
pub const tokens = struct {
    pub const protocol_option = "protocol-option";
    pub const invalid_number = "invalid-number";
    pub const out_of_range = "out-of-range";
    pub const unknown_switch = "unknown-switch";
    pub const unexpected_value = "unexpected-value";
    pub const missing_value = "missing-value";
    pub const conflicting_payload = "conflicting-payload";
    pub const local_port_conflict = "local-port-conflict";
    pub const quota_overflow = "quota-overflow";
    pub const payload_size = "payload-size";
    pub const memory_capacity = "memory-capacity";
    pub const cq_capacity = "cq-capacity";
    pub const missing_target = "missing-target";
    pub const missing_protocol = "missing-protocol";
    pub const unexpected_target = "unexpected-target";
};

/// Usage text, printed on stdout for a valid /h command line and on stderr for a usage error.
pub const usage =
    "Usage: zig-echo-client target /p tcp|udp [/r port] [/l port] [/n count]\n" ++
    "       [/t seconds] [/i ms] [/d text | /z bytes | /zt bytes] [/k tcp-depth]\n" ++
    "       [/c sessions] [/threads workers] [/w seconds] [/rc [seconds]]\n" ++
    "       [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
    "Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.\n";

const std = @import("std");
const win32 = @import("win32.zig");

pub fn checkedProduct(left: usize, right: usize) ?usize {
    const pair = @mulWithOverflow(left, right);
    if (pair[1] != 0) return null;
    return pair[0];
}

pub fn checkedStorageBytes(sessions: usize, batch_bytes: usize, memory_limit: u64) ?usize {
    const per_session = checkedProduct(batch_bytes, 2) orelse return null;
    const total = checkedProduct(sessions, per_session) orelse return null;
    if (total > memory_limit) return null;
    return total;
}

pub fn claimAttempts(claimed: *std.atomic.Value(u64), limit: u64, requested: u64) u64 {
    if (requested == 0) return 0;
    if (limit == 0) {
        _ = claimed.fetchAdd(requested, .monotonic);
        return requested;
    }
    var observed = claimed.load(.monotonic);
    while (true) {
        if (observed >= limit) return 0;
        const granted = @min(requested, limit - observed);
        if (claimed.cmpxchgWeak(observed, observed + granted, .monotonic, .monotonic)) |actual| {
            observed = actual;
        } else return granted;
    }
}

/// /n is a per-session quota. The grant is computed against the session's own claimed counter,
/// while the worker keeps the aggregate of every grant for the terminal accounting. A single worker
/// thread owns its sessions, so a plain counter is enough here.
pub fn claimSessionAttempts(claimed: *u64, limit: u64, requested: u64) u64 {
    if (requested == 0) return 0;
    if (limit == 0) {
        claimed.* += requested;
        return requested;
    }
    if (claimed.* >= limit) return 0;
    const granted = @min(requested, limit - claimed.*);
    claimed.* += granted;
    return granted;
}

pub fn unclaimedEchoes(limit: u64, claimed: u64, controlled_stop: bool) u64 {
    if (controlled_stop or limit == 0 or claimed >= limit) return 0;
    return limit - claimed;
}

pub fn percentileTarget(total: u64, numerator: u64, denominator: u64) u64 {
    if (total == 0 or numerator == 0 or denominator == 0 or numerator > denominator) return 0;
    const q = total / denominator;
    const r = total % denominator;
    return q * numerator + (r * numerator + denominator - 1) / denominator;
}

pub fn classifyResult(echoed: u64, corrupted: u64, lost: u64, network_errors: u64, fatal: bool, controlled_stop: bool) u8 {
    _ = network_errors;
    if (fatal) return 4;
    if (corrupted != 0 or lost != 0) return 3;
    if (controlled_stop) return 0;
    if (echoed == 0) return 2;
    return 0;
}

pub fn notificationMarkDelivered(armed: *bool) bool {
    if (!armed.*) return false;
    armed.* = false;
    return true;
}

pub fn notificationMarkRearmed(armed: *bool) bool {
    if (armed.*) return false;
    armed.* = true;
    return true;
}

test "claim finite attempts" {
    var claimed = std.atomic.Value(u64).init(0);
    try std.testing.expectEqual(@as(u64, 4), claimAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 1), claimAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 0), claimAttempts(&claimed, 5, 4));
}

test "storage accounting" {
    try std.testing.expectEqual(@as(?usize, 800), checkedStorageBytes(4, 100, 800));
    try std.testing.expect(checkedStorageBytes(4, 100, 799) == null);
}

test "unclaimed and result classification" {
    try std.testing.expectEqual(@as(u64, 2), unclaimedEchoes(5, 3, false));
    try std.testing.expectEqual(@as(u64, 0), unclaimedEchoes(5, 3, true));
    try std.testing.expectEqual(@as(u8, 0), classifyResult(5, 0, 0, 0, false, false));
    try std.testing.expectEqual(@as(u8, 2), classifyResult(0, 0, 0, 1, false, false));
    try std.testing.expectEqual(@as(u8, 3), classifyResult(4, 1, 0, 0, false, false));
    try std.testing.expectEqual(@as(u8, 4), classifyResult(0, 0, 0, 0, true, false));
}

const types = @import("types.zig");

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn isSwitch(token: []const u8) bool {
    if (token.len < 2 or (token[0] != '/' and token[0] != '-')) return false;
    const offset: usize = if (token.len > 2 and token[0] == '-' and token[1] == '-') 2 else 1;
    if (offset >= token.len) return false;
    return std.ascii.isAlphabetic(token[offset]);
}
fn number(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |character| if (character < '0' or character > '9') return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}
fn setError(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const count = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..count], message[0..count]);
    buffer[count] = 0;
}
fn copyWtf16(input: []const u8, destination: []u16, length: *u16) bool {
    const count = std.unicode.wtf8ToWtf16Le(destination[0 .. destination.len - 1], input) catch return false;
    if (count >= destination.len or count > std.math.maxInt(u16)) return false;
    destination[count] = 0;
    length.* = @intCast(count);
    return true;
}

pub fn parseArgs(argv: []const []const u8, out: *types.Options, error_buffer: []u8) bool {
    out.* = .{};
    if (error_buffer.len != 0) error_buffer[0] = 0;
    var saw_host = false;
    var saw_pipeline = false;
    var saw_literal = false;
    var saw_binary = false;
    var saw_printable = false;
    // A second positional is reported after the cross-field rules, exactly as the reference does.
    var saw_extra_target = false;
    // UTF-8 byte counts, which is how the reference measures a payload before any session exists.
    var literal_bytes: u64 = 0;
    var host_bytes: u64 = 0;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (!isSwitch(token)) {
            if (saw_host) {
                saw_extra_target = true;
                continue;
            }
            if (token.len == 0 or !copyWtf16(token, &out.host, &out.host_len)) {
                setError(error_buffer, "client requires exactly one valid target host");
                return false;
            }
            saw_host = true;
            host_bytes = token.len;
            continue;
        }
        const body = if (token[0] == '-' and token.len > 1 and token[1] == '-') token[2..] else token[1..];
        const separator = std.mem.indexOfScalar(u8, body, '=');
        const name = if (separator) |position| body[0..position] else body;
        const inline_value: ?[]const u8 = if (separator) |position| body[position + 1 ..] else null;
        if (eq(name, "q") or eq(name, "quiet") or eq(name, "stats") or eq(name, "h") or eq(name, "help")) {
            if (inline_value != null) {
                // A flag never takes a value, and an empty one is still a value.
                setError(error_buffer, tokens.unexpected_value);
                return false;
            }
            if (eq(name, "q") or eq(name, "quiet")) out.quiet = true;
            if (eq(name, "stats")) out.stats = true;
            if (eq(name, "h") or eq(name, "help")) out.help = true;
            continue;
        }
        if (eq(name, "rc") and inline_value == null and (index + 1 >= argv.len or isSwitch(argv[index + 1]))) {
            out.reconnect_seconds = 1;
            continue;
        }
        if (switchInfo(name) == null) {
            setError(error_buffer, tokens.unknown_switch);
            return false;
        }
        const value = inline_value orelse value: {
            if (index + 1 >= argv.len or isSwitch(argv[index + 1])) {
                setError(error_buffer, tokens.missing_value);
                return false;
            }
            index += 1;
            break :value argv[index];
        };
        if (value.len == 0) {
            setError(error_buffer, tokens.missing_value);
            return false;
        }
        if (eq(name, "p")) {
            // The reference matches the protocol keyword itself and reports the parse failure as
            // an out-of-range value, not as a protocol-specific message.
            if (eq(value, "tcp")) out.protocol = .tcp else if (eq(value, "udp")) out.protocol = .udp else {
                setError(error_buffer, tokens.out_of_range);
                return false;
            }
            continue;
        }
        if (eq(name, "d")) {
            if (!copyWtf16(value, &out.literal_pattern, &out.literal_len)) {
                setError(error_buffer, "literal text exceeds the Windows command-line limit");
                return false;
            }
            out.pattern_kind = .literal_text;
            literal_bytes = value.len;
            saw_literal = true;
            continue;
        }
        const parsed = number(value) orelse {
            setError(error_buffer, tokens.invalid_number);
            return false;
        };
        const info = switchInfo(name) orelse {
            setError(error_buffer, tokens.unknown_switch);
            return false;
        };
        if (parsed < info.minimum or parsed > info.maximum) {
            setError(error_buffer, tokens.out_of_range);
            return false;
        }
        if (eq(name, "r") and parsed >= 1 and parsed <= 65535) out.remote_port = @intCast(parsed) else if (eq(name, "l") and parsed <= 65535) out.local_port = @intCast(parsed) else if (eq(name, "n")) out.echo_count = parsed else if (eq(name, "t") and parsed >= 1 and parsed <= std.math.maxInt(u32)) out.timeout_seconds = @intCast(parsed) else if (eq(name, "i") and parsed <= std.math.maxInt(u32)) out.interval_milliseconds = @intCast(parsed) else if (eq(name, "b") and parsed <= std.math.maxInt(i32)) out.socket_buffer_bytes = @intCast(parsed) else if (eq(name, "k") and parsed >= 1 and parsed <= 65536) {
            out.pipeline_depth = @intCast(parsed);
            saw_pipeline = true;
        } else if (eq(name, "z") and parsed >= 1 and parsed <= types.maximum_tcp_batch_bytes) {
            out.pattern_kind = .binary_counter;
            out.pattern_bytes = @intCast(parsed);
            saw_binary = true;
        } else if (eq(name, "zt") and parsed >= 1 and parsed <= types.maximum_tcp_batch_bytes) {
            out.pattern_kind = .printable_counter;
            out.pattern_bytes = @intCast(parsed);
            saw_printable = true;
        } else if (eq(name, "w") and parsed >= 1 and parsed <= std.math.maxInt(u32)) out.run_seconds = @intCast(parsed) else if (eq(name, "rc") and parsed <= std.math.maxInt(i32)) out.reconnect_seconds = @intCast(parsed) else if (eq(name, "report") and parsed >= 1 and parsed <= std.math.maxInt(u32)) out.report_seconds = @intCast(parsed) else if (eq(name, "c") and parsed >= 1 and parsed <= 1048576) out.session_count = @intCast(parsed) else if (eq(name, "threads") and parsed >= 1 and parsed <= 64) out.worker_count = @intCast(parsed) else if (eq(name, "cq") and parsed >= 64 and parsed <= 1048576) out.cq_capacity = @intCast(parsed) else if (eq(name, "memory") and parsed >= 1048576) out.memory_bytes = parsed else {
            setError(error_buffer, tokens.out_of_range);
            return false;
        }
    }
    // The cross-field rules keep the reference's precedence: the worker split first, then the
    // positional arguments, the payload conflict, the protocol options, the local-port rules, the
    // quota and only then the payload and capacity budgets.
    if (out.worker_count > out.session_count) {
        setError(error_buffer, tokens.out_of_range);
        return false;
    }
    if (saw_extra_target) {
        setError(error_buffer, tokens.unexpected_target);
        return false;
    }
    // The baseline reports the missing target first and the missing protocol second, so a bare
    // invocation and a host-only invocation are different mistakes. /h suppresses only these two
    // checks; every other rule still applies.
    if (!out.help and !saw_host) {
        setError(error_buffer, tokens.missing_target);
        return false;
    }
    if (!out.help and out.protocol == .none) {
        setError(error_buffer, tokens.missing_protocol);
        return false;
    }
    // @intFromBool is u1, so the sum has to be widened first: two set flags would otherwise
    // overflow the u1 addition and the conflict would go unnoticed.
    const patterns: u8 = @as(u8, @intFromBool(saw_literal)) +
        @as(u8, @intFromBool(saw_binary)) +
        @as(u8, @intFromBool(saw_printable));
    if (patterns > 1) {
        setError(error_buffer, tokens.conflicting_payload);
        return false;
    }
    if (out.protocol == .udp and saw_pipeline and switchInfo("k").?.scope == .tcp_only) {
        setError(error_buffer, tokens.protocol_option);
        return false;
    }
    if (out.local_port != 0 and
        (out.session_count != 1 or (out.protocol == .tcp and out.reconnect_seconds >= 0)))
    {
        setError(error_buffer, tokens.local_port_conflict);
        return false;
    }
    if (out.session_count != 0 and out.echo_count > std.math.maxInt(u64) / @as(u64, out.session_count)) {
        setError(error_buffer, tokens.quota_overflow);
        return false;
    }
    // Nothing else can be validated without a protocol, which is how /h alone succeeds.
    if (out.protocol == .none) return true;
    // Each worker owns its own CQ and its own registered arena, so the largest shard decides both
    // budgets.
    const workers = resolveWorkerCount(out.worker_count, out.session_count);
    const shard: u64 = (@as(u64, out.session_count) + workers - 1) / workers;
    // The effective payload length is known before any session exists.
    const pattern_bytes: u64 = switch (out.pattern_kind) {
        .binary_counter, .printable_counter => out.pattern_bytes,
        .literal_text => literal_bytes,
        .default_text => if (saw_host) default_text_prefix.len + host_bytes else 0,
    };
    if (out.protocol == .udp and pattern_bytes > types.maximum_udp_payload) {
        setError(error_buffer, tokens.payload_size);
        return false;
    }
    if (pattern_bytes != 0) {
        const batch = checkedProduct(@intCast(pattern_bytes), out.pipeline_depth) orelse {
            setError(error_buffer, tokens.payload_size);
            return false;
        };
        if (batch > types.maximum_tcp_batch_bytes) {
            setError(error_buffer, tokens.payload_size);
            return false;
        }
        _ = checkedStorageBytes(out.session_count, batch, out.memory_bytes) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        // One worker registers its whole shard, and a single registration may not exceed DWORD.
        const per_session = checkedProduct(batch, 2) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        const per_worker = checkedProduct(per_session, @intCast(shard)) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        if (per_worker > std.math.maxInt(u32)) {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        }
    }
    // One attempt is one receive plus one send whatever /k is, so the largest shard reserves
    // exactly two operations per session against the completion queue.
    if (shard * 2 > out.cq_capacity) {
        setError(error_buffer, tokens.cq_capacity);
        return false;
    }
    return true;
}

/// The default payload of the baseline.
pub const default_text_prefix = "echo from ";

/// Workers the reference would create: /threads, or the active processor count clamped to [1,64],
/// and never more than there are sessions.
pub fn resolveWorkerCount(configured: u32, sessions: u32) u64 {
    if (sessions == 0) return 1;
    var workers: u64 = configured;
    if (workers == 0) {
        workers = std.math.clamp(@as(u64, win32.c.GetActiveProcessorCount(win32.c.ALL_PROCESSOR_GROUPS)), 1, 64);
    }
    return @min(workers, sessions);
}

pub fn parseProcessArgs(args: std.process.Args, allocator: std.mem.Allocator, out: *types.Options, error_buffer: []u8) bool {
    const process_argv = args.toSlice(allocator) catch {
        setError(error_buffer, "unable to read command line");
        return false;
    };
    if (process_argv.len == 0) {
        setError(error_buffer, "unable to read command line");
        return false;
    }
    return parseArgs(process_argv[1..], out, error_buffer);
}