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
};

/// Usage text, printed on stdout for a valid /h command line and on stderr for a usage error.
pub const usage =
    "Usage: zig-echo-client target /p tcp|udp [/r port] [/l port] [/n count]\n" ++
    "       [/t seconds] [/i ms] [/d text | /z bytes | /zt bytes] [/k tcp-depth]\n" ++
    "       [/c sessions] [/threads workers] [/w seconds] [/rc [seconds]]\n" ++
    "       [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
    "Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.\n";

const std = @import("std");

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
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (!isSwitch(token)) {
            if (saw_host or token.len == 0 or !copyWtf16(token, &out.host, &out.host_len)) {
                setError(error_buffer, "client requires exactly one valid target host");
                return false;
            }
            saw_host = true;
            continue;
        }
        const body = if (token[0] == '-' and token.len > 1 and token[1] == '-') token[2..] else token[1..];
        const separator = std.mem.indexOfScalar(u8, body, '=');
        const name = if (separator) |position| body[0..position] else body;
        const inline_value: ?[]const u8 = if (separator) |position| body[position + 1 ..] else null;
        if (inline_value) |value| if (value.len == 0) {
            setError(error_buffer, "switch requires a non-empty inline value");
            return false;
        };
        if (eq(name, "q") or eq(name, "quiet") or eq(name, "stats") or eq(name, "h") or eq(name, "help")) {
            if (inline_value != null) {
                setError(error_buffer, "flag switch does not accept a value");
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
                setError(error_buffer, "switch requires a non-empty value");
                return false;
            }
            index += 1;
            break :value argv[index];
        };
        if (value.len == 0) {
            setError(error_buffer, "switch requires a non-empty value");
            return false;
        }
        if (eq(name, "p")) {
            if (eq(value, "tcp")) out.protocol = .tcp else if (eq(value, "udp")) out.protocol = .udp else {
                setError(error_buffer, "/p requires tcp or udp");
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
    if (out.local_port != 0 and out.session_count != 1) {
        setError(error_buffer, "a fixed /l port requires /c 1");
        return false;
    }
    if (out.protocol == .udp and saw_pipeline and switchInfo("k").?.scope == .tcp_only) {
        setError(error_buffer, tokens.protocol_option);
        return false;
    }
    if (out.help) return true;
    // The baseline reports the missing target first and the missing protocol second, so a bare
    // invocation and a host-only invocation are different mistakes.
    if (!saw_host) {
        setError(error_buffer, "missing-target");
        return false;
    }
    if (out.protocol == .none) {
        setError(error_buffer, "missing-protocol");
        return false;
    }
    const patterns: u8 = @intFromBool(saw_literal) + @intFromBool(saw_binary) + @intFromBool(saw_printable);
    if (patterns > 1) {
        setError(error_buffer, "use exactly one of /d, /z, or /zt");
        return false;
    }
    if (out.protocol == .tcp and out.reconnect_seconds >= 0 and out.local_port != 0) {
        setError(error_buffer, "TCP reconnect cannot use a fixed /l port");
        return false;
    }
    if (out.protocol == .udp and out.pattern_bytes > types.maximum_udp_payload) {
        setError(error_buffer, "UDP payload must not exceed 65507 bytes");
        return false;
    }
    if (out.pattern_bytes != 0) {
        const batch = checkedProduct(out.pattern_bytes, out.pipeline_depth) orelse {
            setError(error_buffer, "TCP payload multiplied by depth overflowed");
            return false;
        };
        if (batch > types.maximum_tcp_batch_bytes) {
            setError(error_buffer, "TCP payload multiplied by depth must not exceed 64 MiB");
            return false;
        }
        _ = checkedStorageBytes(out.session_count, batch, out.memory_bytes) orelse {
            setError(error_buffer, "registered storage exceeds /memory");
            return false;
        };
    }
    return true;
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