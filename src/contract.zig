//! The client binary's contract, in one place: the command line (switches, ranges, diagnostic
//! tokens, usage text), the capacity budgets and the shared classification helpers.
//!
//! Reference implementation: echo-binary-contract-v1 (the C++ client). The parser reproduces the
//! reference's token-consumption order, its diagnostic precedence and its cross-field rules, so a
//! command line produces the same diagnostic in every implementation.

const std = @import("std");
const native = @import("native.zig");
const payload = @import("payload.zig");
const types = @import("types.zig");

/// Identifier of the frozen binary contract this file implements.
pub const version = types.contract_version;

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
    pub const invalid_utf16 = "invalid-utf16";
};

/// Usage text, printed on stdout for a valid help command line and on stderr for a usage error.
pub const usage =
    "Usage: zig-echo-client target /p tcp|udp [/r port] [/l port] [/n count] [/t seconds] [/i ms]\n       [/d " ++
    "text | /z bytes | /zt bytes] [/k depth] [/c sessions]\n       [/threads workers] [/w seconds] [/rc " ++
    "[seconds]] [/report seconds]\n       [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats] [/h]\n/n " ++
    "count: attempts per session; 0 means unlimited.\n/k depth: TCP requests in flight per session; UDP " ++
    "rejects /k.\n/threads 0: automatic workers, min(sessions, active processors, 64).\n/rc [seconds]: " ++
    "reconnect after failure; bare /rc means 1 second.\n/w 0: no run limit. /report 0: no periodic " ++
    "reports.\n/q suppresses the default final; /stats forces final; /h shows help.\n";

/// Which protocol a switch belongs to; the parser rejects a switch used with the wrong one.
pub const Scope = enum { both, tcp_only, udp_only };

pub const Switch = struct {
    name: []const u8,
    minimum: u64,
    maximum: u64,
    scope: Scope,
};

/// The value switches this client accepts, as compile-time data: the accepted set, its ranges and
/// its protocol scope live in exactly one place.
///
/// An explicit zero is valid wherever the reference accepts one: the echo quota means "unlimited",
/// the run duration and report interval mean "disabled", the worker count means "automatic", and
/// the reconnect delay means "reconnect immediately".
pub const switch_table = [_]Switch{
    .{ .name = "p", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "r", .minimum = 1, .maximum = 65_535, .scope = .both },
    .{ .name = "l", .minimum = 0, .maximum = 65_535, .scope = .both },
    .{ .name = "n", .minimum = 0, .maximum = std.math.maxInt(u64), .scope = .both },
    .{ .name = "t", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "i", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "d", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "z", .minimum = 1, .maximum = types.maximum_tcp_batch_bytes, .scope = .both },
    .{ .name = "zt", .minimum = 1, .maximum = types.maximum_tcp_batch_bytes, .scope = .both },
    .{ .name = "k", .minimum = 1, .maximum = 65_536, .scope = .tcp_only },
    .{ .name = "c", .minimum = 1, .maximum = types.maximum_sessions, .scope = .both },
    .{ .name = "threads", .minimum = 0, .maximum = 64, .scope = .both },
    .{ .name = "w", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "rc", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "report", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "b", .minimum = 0, .maximum = 2_147_483_647, .scope = .both },
    .{ .name = "cq", .minimum = 64, .maximum = 1_048_576, .scope = .both },
    .{ .name = "memory", .minimum = 1_048_576, .maximum = std.math.maxInt(u64), .scope = .both },
};

comptime {
    // The pipeline switch is a TCP pipeline depth: the parser rejects it for UDP under the
    // protocol-option token, so the table and the cross-field rule may never disagree. The three
    // explicit-zero switches are named here as well, because a range change that silently started
    // rejecting them would be a contract break rather than a tuning change.
    if (switchInfo("k").?.scope != .tcp_only) @compileError("switch k must stay TCP only");
    if (switchInfo("threads").?.minimum != 0) @compileError("explicit /threads 0 must stay valid");
    if (switchInfo("w").?.minimum != 0) @compileError("explicit /w 0 must stay valid");
    if (switchInfo("report").?.minimum != 0) @compileError("explicit /report 0 must stay valid");
}

/// Compile-time lookup: the table is unrolled by the compiler, so a typo here is a build error
/// rather than a runtime miss.
pub fn switchInfo(name: []const u8) ?Switch {
    inline for (switch_table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry;
    }
    return null;
}

pub const checkedProduct = types.checkedProduct;
pub const ceilingDivide = types.ceilingDivide;

/// Registered bytes the run must be able to afford: two directions for every session.
pub fn checkedStorageBytes(sessions: u32, batch_bytes: u64, memory_limit: u64) ?u64 {
    const one_direction = types.checkedProduct(u64, batch_bytes, @as(u64, sessions)) orelse return null;
    const total = types.checkedProduct(u64, one_direction, 2) orelse return null;
    if (total > memory_limit) return null;
    return total;
}

pub fn unclaimedEchoes(limit: u64, claimed: u64, controlled_stop: bool) u64 {
    if (controlled_stop or limit == 0 or claimed >= limit) return 0;
    return limit - claimed;
}

/// The exit code is a property of the ledger, not of the transport: a fatal internal failure wins,
/// then any corrupted or lost echo, then a run that never echoed anything at all.
pub fn classifyResult(echoed: u64, corrupted: u64, lost: u64, network_errors: u64, fatal: bool, controlled_stop: bool) u8 {
    _ = network_errors;
    if (fatal) return @backingInt(types.ExitCode.internal);
    if (corrupted != 0 or lost != 0) return @backingInt(types.ExitCode.echo_failure);
    if (controlled_stop) return @backingInt(types.ExitCode.success);
    if (echoed == 0) return @backingInt(types.ExitCode.network);
    return @backingInt(types.ExitCode.success);
}

/// Histogram percentile target: ceil(total * numerator / denominator) without overflowing the
/// product, which is what makes the reported value an approximation of the requested percentile.
pub fn percentileTarget(total: u64, numerator: u64, denominator: u64) u64 {
    if (total == 0 or numerator == 0 or denominator == 0 or numerator > denominator) return 0;
    const quotient = total / denominator;
    const remainder = total % denominator;
    const scaled = types.ceilingDivide(u64, remainder *| numerator, denominator);
    return (quotient *| numerator) +| scaled;
}

/// Workers the reference would create: the worker switch, or the active processor count clamped to
/// [1, 64], and never more than there are sessions.
pub fn resolveWorkerCount(configured: u32, sessions: u32) u64 {
    const workers = types.resolvedWorkerCount(configured, native.processorCount());
    return @max(@min(workers, @as(u64, sessions)), 1);
}

fn eq(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
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

/// Windows supplies command-line arguments as WTF-8, where an unpaired surrogate is encoded as a
/// three-byte sequence starting with 0xED. A valid surrogate pair is always a single four-byte
/// sequence, so this pattern can only ever be a lone surrogate.
fn hasLoneSurrogate(bytes: []const u8) bool {
    var index: usize = 0;
    while (index + 2 < bytes.len) : (index += 1) {
        if (bytes[index] == 0xED and bytes[index + 1] >= 0xA0 and bytes[index + 1] <= 0xBF) return true;
    }
    return false;
}

fn setError(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const count = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..count], message[0..count]);
    buffer[count] = 0;
}

/// Converts WTF-8 into WTF-16 in place. The length is measured first because the converter assumes
/// its output is already large enough, and an oversized argument must be a diagnostic rather than a
/// write past the end of the caller's buffer.
fn copyWtf16(input: []const u8, destination: []u16, length: *u16) bool {
    const units = std.unicode.calcWtf16LeLen(input) catch return false;
    if (units >= destination.len or units > std.math.maxInt(u16)) return false;
    const count = std.unicode.wtf8ToWtf16Le(destination[0..units], input) catch return false;
    destination[count] = 0;
    length.* = @intCast(count);
    return true;
}

/// The effective payload length, known before any session exists: the counter payloads carry their
/// own length, while the literal and default texts are measured in UTF-8 bytes exactly as the
/// reference measures them through WideCharToMultiByte.
fn effectivePayloadBytes(options: *const types.Options, literal_bytes: u64, host_bytes: u64, saw_host: bool) u64 {
    return switch (options.pattern_kind) {
        .binary_counter, .printable_counter => options.pattern_bytes,
        .literal_text => literal_bytes,
        .default_text => if (saw_host) payload.default_text_prefix.len + host_bytes else 0,
    };
}

pub fn parseArgs(argv: []const []const u8, out: *types.Options, error_buffer: []u8) bool {
    out.* = .{};
    if (error_buffer.len != 0) error_buffer[0] = 0;
    var saw_host = false;
    var saw_pipeline = false;
    var saw_literal = false;
    var saw_binary = false;
    var saw_printable = false;
    // A second positional is reported after the mandatory arguments, exactly as the reference
    // reports it, so the worker split still wins when both are wrong.
    var saw_extra_target = false;
    var literal_invalid_utf16 = false;
    var literal_bytes: u64 = 0;
    var host_bytes: u64 = 0;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (hasLoneSurrogate(token)) {
            setError(error_buffer, tokens.invalid_utf16);
            return false;
        }
        if (!isSwitch(token)) {
            if (saw_host) {
                saw_extra_target = true;
                continue;
            }
            if (token.len == 0) {
                // An empty positional is a value problem, not a missing one.
                setError(error_buffer, tokens.out_of_range);
                return false;
            }
            if (!copyWtf16(token, &out.host, &out.host_len)) {
                setError(error_buffer, tokens.out_of_range);
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
        var value_invalid_utf16 = false;
        const value = inline_value orelse value_block: {
            if (index + 1 >= argv.len or argv[index + 1].len == 0 or isSwitch(argv[index + 1])) {
                setError(error_buffer, tokens.missing_value);
                return false;
            }
            index += 1;
            value_invalid_utf16 = hasLoneSurrogate(argv[index]);
            break :value_block argv[index];
        };
        if (value.len == 0) {
            // A value that was written but left empty is absent, whichever form the switch used.
            setError(error_buffer, tokens.missing_value);
            return false;
        }
        if (eq(name, "p")) {
            // The reference matches the protocol keyword itself and reports the parse failure as an
            // out-of-range value, not as a protocol-specific message.
            if (eq(value, "tcp")) out.protocol = .tcp else if (eq(value, "udp")) out.protocol = .udp else {
                setError(error_buffer, tokens.out_of_range);
                return false;
            }
            continue;
        }
        if (eq(name, "d")) {
            // The literal is measured in UTF-16 units, exactly like the reference, and the same
            // capacity check applies whatever the protocol is.
            if (!copyWtf16(value, &out.literal_pattern, &out.literal_len)) {
                setError(error_buffer, tokens.out_of_range);
                return false;
            }
            out.pattern_kind = .literal_text;
            literal_bytes = value.len;
            literal_invalid_utf16 = value_invalid_utf16;
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
        if (eq(name, "r")) {
            out.remote_port = @intCast(parsed);
        } else if (eq(name, "l")) {
            out.local_port = @intCast(parsed);
        } else if (eq(name, "n")) {
            out.echo_count = parsed;
        } else if (eq(name, "t")) {
            out.timeout_seconds = @intCast(parsed);
        } else if (eq(name, "i")) {
            out.interval_milliseconds = @intCast(parsed);
        } else if (eq(name, "b")) {
            out.socket_buffer_bytes = @intCast(parsed);
        } else if (eq(name, "k")) {
            saw_pipeline = true;
            out.pipeline_depth = @intCast(parsed);
        } else if (eq(name, "z")) {
            saw_binary = true;
            out.pattern_kind = .binary_counter;
            out.pattern_bytes = @intCast(parsed);
        } else if (eq(name, "zt")) {
            saw_printable = true;
            out.pattern_kind = .printable_counter;
            out.pattern_bytes = @intCast(parsed);
        } else if (eq(name, "w")) {
            out.run_seconds = @intCast(parsed);
        } else if (eq(name, "rc")) {
            out.reconnect_seconds = @intCast(parsed);
        } else if (eq(name, "report")) {
            out.report_seconds = @intCast(parsed);
        } else if (eq(name, "c")) {
            out.session_count = @intCast(parsed);
        } else if (eq(name, "threads")) {
            out.worker_count = @intCast(parsed);
        } else if (eq(name, "cq")) {
            out.cq_capacity = @intCast(parsed);
        } else if (eq(name, "memory")) {
            out.memory_bytes = parsed;
        } else {
            setError(error_buffer, tokens.unknown_switch);
            return false;
        }
    }
    // The cross-field rules keep the reference's precedence: the worker split first, then the two
    // mandatory arguments, the extra positional, the payload conflict, the protocol options, the
    // local-port rules, the quota, and only then the payload and capacity budgets.
    if (out.worker_count > out.session_count) {
        setError(error_buffer, tokens.out_of_range);
        return false;
    }
    // The help switch suppresses the two mandatory-argument checks and nothing else: every other
    // rule, including the capacity budgets, still applies exactly as it does without it.
    if (!out.help and !saw_host) {
        setError(error_buffer, tokens.missing_target);
        return false;
    }
    if (saw_extra_target) {
        setError(error_buffer, tokens.unexpected_target);
        return false;
    }
    if (!out.help and out.protocol == .none) {
        setError(error_buffer, tokens.missing_protocol);
        return false;
    }
    // The @intFromBool results are u1, so the sum has to be widened first: two set flags would
    // otherwise overflow the u1 addition and the conflict would go unnoticed.
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
        (out.session_count != 1 or (out.protocol == .tcp and out.reconnect_seconds != null)))
    {
        setError(error_buffer, tokens.local_port_conflict);
        return false;
    }
    if (out.session_count != 0 and out.echo_count > std.math.maxInt(u64) / @as(u64, out.session_count)) {
        setError(error_buffer, tokens.quota_overflow);
        return false;
    }
    if (out.pattern_kind == .literal_text and literal_invalid_utf16) {
        setError(error_buffer, tokens.invalid_utf16);
        return false;
    }
    const pattern_bytes = effectivePayloadBytes(out, literal_bytes, host_bytes, saw_host);
    if (out.protocol == .udp and pattern_bytes > types.maximum_udp_payload) {
        setError(error_buffer, tokens.payload_size);
        return false;
    }
    // Nothing else can be validated without a protocol, which is how a bare help command line
    // succeeds.
    if (out.protocol == .none) return true;
    // Each worker owns its own completion queue and its own registered arena, so the largest shard
    // decides both budgets.
    const workers = resolveWorkerCount(out.worker_count, out.session_count);
    const shard = ceilingDivide(u64, out.session_count, workers);
    if (pattern_bytes != 0) {
        const batch = types.checkedProduct(u64, pattern_bytes, out.pipeline_depth) orelse {
            setError(error_buffer, tokens.payload_size);
            return false;
        };
        if (batch > types.maximum_tcp_batch_bytes) {
            setError(error_buffer, tokens.payload_size);
            return false;
        }
        const storage = types.checkedProduct(u64, batch, out.session_count) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        const both = types.checkedProduct(u64, storage, 2) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        const per_session = types.checkedProduct(u64, batch, 2) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        const per_worker = types.checkedProduct(u64, per_session, shard) orelse {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        };
        if (both > out.memory_bytes or per_worker > std.math.maxInt(u32)) {
            setError(error_buffer, tokens.memory_capacity);
            return false;
        }
    }
    // One attempt is one receive plus one send whatever the pipeline depth is, so the largest shard
    // reserves exactly two operations per session against the completion queue.
    if (shard * 2 > out.cq_capacity) {
        setError(error_buffer, tokens.cq_capacity);
        return false;
    }
    return true;
}

pub fn parseProcessArgs(args: std.process.Args, out: *types.Options, error_buffer: []u8) bool {
    // A Windows command line is limited to 32,767 UTF-16 units including its terminator.
    // Each unit needs at most three WTF-8 bytes. Each argument after argv[0] consumes at
    // least one character and one separator, including empty quoted arguments. These
    // bounds keep the CRT-compatible iterator and every argument view on the stack, so
    // parsing does not introduce an allocation failure absent from the C++ parser.
    const command_line_capacity = 32_768;
    if (args.vector.len > command_line_capacity) {
        setError(error_buffer, "invalid parser arguments");
        return false;
    }
    var bytes: [command_line_capacity * 3 + 1]u8 = undefined;
    var storage = std.heap.FixedBufferAllocator.init(&bytes);
    var iterator = args.iterateAllocator(storage.allocator()) catch
        native.diagnostics.failFast("command line storage", native.sdk.c.ERROR_INSUFFICIENT_BUFFER);
    defer iterator.deinit();
    var argv: [command_line_capacity / 2 + 1][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |argument| {
        if (count == argv.len) native.diagnostics.failFast("command line argument count", native.sdk.c.ERROR_INSUFFICIENT_BUFFER);
        argv[count] = argument;
        count += 1;
    }
    // The CRT synthesizes argv[0] for an empty command line. Its spelling is irrelevant
    // to the option parser, which skips the executable name in either case.
    return parseArgs(if (count == 0) argv[0..0] else argv[1..count], out, error_buffer);
}
