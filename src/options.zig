const std = @import("std");
const types = @import("types.zig");
const contract = @import("contract.zig");

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
        const known = eq(name, "p") or eq(name, "r") or eq(name, "l") or eq(name, "n") or eq(name, "t") or eq(name, "i") or
            eq(name, "d") or eq(name, "z") or eq(name, "zt") or eq(name, "k") or eq(name, "c") or eq(name, "threads") or
            eq(name, "w") or eq(name, "rc") or eq(name, "report") or eq(name, "b") or eq(name, "cq") or eq(name, "memory");
        if (!known) {
            setError(error_buffer, @import("cec_contract.zig").token.unknown_switch);
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
            setError(error_buffer, @import("cec_contract.zig").token.invalid_number);
            return false;
        };
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
            setError(error_buffer, @import("cec_contract.zig").token.out_of_range);
            return false;
        }
    }
    if (out.local_port != 0 and out.session_count != 1) {
        setError(error_buffer, "a fixed /l port requires /c 1");
        return false;
    }
    if (out.protocol == .udp and saw_pipeline) {
        setError(error_buffer, @import("cec_contract.zig").token.protocol_option);
        return false;
    }
    if (out.help) return true;
    if (!saw_host or out.protocol == .none) {
        setError(error_buffer, "target host and /p tcp or /p udp are required");
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
        const batch = contract.checkedProduct(out.pattern_bytes, out.pipeline_depth) orelse {
            setError(error_buffer, "TCP payload multiplied by depth overflowed");
            return false;
        };
        if (batch > types.maximum_tcp_batch_bytes) {
            setError(error_buffer, "TCP payload multiplied by depth must not exceed 64 MiB");
            return false;
        }
        _ = contract.checkedStorageBytes(out.session_count, batch, out.memory_bytes) orelse {
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
