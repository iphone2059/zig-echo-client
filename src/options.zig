const std = @import("std");
const types = @import("types.zig");
const contract = @import("contract.zig");

pub const ParseError = error{InvalidArguments};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn isSwitch(token: []const u8) bool {
    return token.len >= 2 and (token[0] == '/' or token[0] == '-');
}
fn number(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch null;
}
fn setError(buf: []u8, msg: []const u8) void {
    if (buf.len == 0) return;
    const n = @min(buf.len - 1, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
}
fn fail(buf: []u8, msg: []const u8) ParseError {
    setError(buf, msg);
    return error.InvalidArguments;
}

pub fn parse(allocator: std.mem.Allocator, error_buffer: []u8) ParseError!types.Options {
    var it = std.process.argsWithAllocator(allocator) catch return fail(error_buffer, "unable to read command line");
    defer it.deinit();
    _ = it.skip();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (it.next()) |arg| argv.append(allocator, arg) catch return fail(error_buffer, "out of memory while parsing arguments");

    var out: types.Options = .{};
    var saw_host = false;
    var saw_pipeline = false;
    var saw_literal = false;
    var saw_binary = false;
    var saw_printable = false;

    var i: usize = 0;
    while (i < argv.items.len) : (i += 1) {
        const token = argv.items[i];
        if (!isSwitch(token)) {
            if (saw_host or token.len == 0 or token.len >= 256) return fail(error_buffer, "client requires exactly one valid target host");
            out.host = token;
            saw_host = true;
            continue;
        }
        const body = if (token[0] == '-' and token.len > 1 and token[1] == '-') token[2..] else token[1..];
        const sep = std.mem.indexOfScalar(u8, body, '=');
        const name = if (sep) |p| body[0..p] else body;
        const inline_value: ?[]const u8 = if (sep) |p| body[p + 1 ..] else null;
        if (inline_value) |v| {
            if (v.len == 0) return fail(error_buffer, "switch requires a non-empty inline value");
        }

        if (eq(name, "q") or eq(name, "quiet") or eq(name, "stats") or eq(name, "h") or eq(name, "help")) {
            if (inline_value != null) return fail(error_buffer, "flag switch does not accept a value");
            if (eq(name, "q") or eq(name, "quiet")) out.quiet = true;
            if (eq(name, "stats")) out.stats = true;
            if (eq(name, "h") or eq(name, "help")) out.help = true;
            continue;
        }
        if (eq(name, "rc") and inline_value == null and (i + 1 >= argv.items.len or isSwitch(argv.items[i + 1]))) {
            out.reconnect_seconds = 1;
            continue;
        }
        const known = eq(name, "p") or eq(name, "r") or eq(name, "l") or eq(name, "n") or eq(name, "t") or eq(name, "i") or
            eq(name, "d") or eq(name, "z") or eq(name, "zt") or eq(name, "k") or eq(name, "c") or eq(name, "threads") or
            eq(name, "w") or eq(name, "rc") or eq(name, "report") or eq(name, "b") or eq(name, "cq") or eq(name, "memory");
        if (!known) return fail(error_buffer, "unknown switch");
        const value = inline_value orelse blk: {
            if (i + 1 >= argv.items.len or isSwitch(argv.items[i + 1])) return fail(error_buffer, "switch requires a non-empty value");
            i += 1;
            break :blk argv.items[i];
        };

        if (eq(name, "p")) {
            if (eq(value, "tcp")) {
                out.protocol = .tcp;
            } else if (eq(value, "udp")) {
                out.protocol = .udp;
            } else {
                return fail(error_buffer, "/p requires tcp or udp");
            }
            continue;
        }
        if (eq(name, "d")) {
            if (!std.unicode.utf8ValidateSlice(value)) return fail(error_buffer, "/d must be valid UTF-8");
            out.literal_pattern = value;
            out.pattern_kind = .literal_text;
            saw_literal = true;
            continue;
        }
        const n = number(value) orelse return fail(error_buffer, "numeric switch has an invalid value");
        if (eq(name, "r") and n >= 1 and n <= 65535) {
            out.remote_port = @intCast(n);
        } else if (eq(name, "l") and n <= 65535) {
            out.local_port = @intCast(n);
        } else if (eq(name, "n")) {
            out.echo_count = n;
        } else if (eq(name, "t") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.timeout_seconds = @intCast(n);
        } else if (eq(name, "i") and n <= std.math.maxInt(u32)) {
            out.interval_milliseconds = @intCast(n);
        } else if (eq(name, "b") and n <= @as(u64, std.math.maxInt(i32))) {
            out.socket_buffer_bytes = @intCast(n);
        } else if (eq(name, "k") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.pipeline_depth = @intCast(n);
            saw_pipeline = true;
        } else if (eq(name, "z") and n >= 1 and n <= types.maximum_tcp_batch_bytes) {
            out.pattern_kind = .binary_counter;
            out.pattern_bytes = @intCast(n);
            saw_binary = true;
        } else if (eq(name, "zt") and n >= 1 and n <= types.maximum_tcp_batch_bytes) {
            out.pattern_kind = .printable_counter;
            out.pattern_bytes = @intCast(n);
            saw_printable = true;
        } else if (eq(name, "w") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.run_seconds = @intCast(n);
        } else if (eq(name, "rc") and n <= @as(u64, std.math.maxInt(i32))) {
            out.reconnect_seconds = @intCast(n);
        } else if (eq(name, "report") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.report_seconds = @intCast(n);
        } else if (eq(name, "c") and n >= 1 and n <= 1048576) {
            out.session_count = @intCast(n);
        } else if (eq(name, "threads") and n >= 1 and n <= 64) {
            out.worker_count = @intCast(n);
        } else if (eq(name, "cq") and n >= 64 and n <= 1048576) {
            out.cq_capacity = @intCast(n);
        } else if (eq(name, "memory") and n >= 1048576) {
            out.memory_bytes = n;
        } else {
            return fail(error_buffer, "unknown switch or value outside its valid range");
        }
    }

    if (out.local_port != 0 and out.session_count != 1) return fail(error_buffer, "a fixed /l port requires /c 1");
    if (out.help) return out;
    if (!saw_host or out.protocol == .none) return fail(error_buffer, "target host and /p tcp or /p udp are required");
    const pattern_switches: u8 = @intFromBool(saw_literal) + @intFromBool(saw_binary) + @intFromBool(saw_printable);
    if (pattern_switches > 1) return fail(error_buffer, "use exactly one of /d, /z, or /zt");
    if (out.protocol == .udp and saw_pipeline) return fail(error_buffer, "/k is available only for TCP");
    if (out.protocol == .tcp and out.reconnect_seconds >= 0 and out.local_port != 0) return fail(error_buffer, "TCP reconnect cannot use a fixed /l port");
    if (out.protocol == .udp and out.pattern_bytes > types.maximum_udp_payload) return fail(error_buffer, "UDP payload must not exceed 65507 bytes");
    if (out.pattern_bytes != 0) {
        const batch = contract.checkedProduct(out.pattern_bytes, out.pipeline_depth) orelse return fail(error_buffer, "TCP payload multiplied by depth overflowed");
        if (batch > types.maximum_tcp_batch_bytes) return fail(error_buffer, "TCP payload multiplied by depth must not exceed 64 MiB");
        _ = contract.checkedStorageBytes(out.session_count, batch, out.memory_bytes) orelse return fail(error_buffer, "registered storage exceeds /memory");
    }
    return out;
}
