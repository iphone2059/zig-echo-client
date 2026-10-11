const std = @import("std");
const client = @import("client");

fn parse(argv: []const []const u8, out: *client.types.Options, error_buffer: []u8) bool {
    return client.contract.parseArgs(argv, out, error_buffer);
}

test "client parses exact concurrent workload and owns UTF-16 host literal" {
    var options: client.types.Options = .{};
    var error_buffer: [client.types.error_capacity]u8 = @splat(0);
    var host = [_]u8{ 'h', 'o', 's', 't' };
    var literal = [_]u8{ 'h', 0xc3, 0xa9 };
    const argv = [_][]const u8{ &host, "/P", "TCP", "/r", "4578", "/n", "1000", "/k", "8", "/d", &literal, "/c", "32", "/threads", "4", "/q" };
    try std.testing.expect(parse(&argv, &options, &error_buffer));
    host[0] = 'X';
    literal[0] = 'X';
    try std.testing.expectEqualStrings("host", options.hostUtf8(&error_buffer) catch unreachable);
    try std.testing.expectEqualSlices(u16, &.{ 'h', 0x00e9 }, options.literalUtf16());
    try std.testing.expectEqual(@as(u32, 8), options.pipeline_depth);
    try std.testing.expectEqual(@as(u32, 32), options.session_count);
}

test "client rejects empty values conflicts and malformed WTF-8" {
    var options: client.types.Options = .{};
    var error_buffer: [client.types.error_capacity]u8 = @splat(0);
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/r=" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/l", "40000", "/rc" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "udp", "/k", "2" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ &.{0xff}, "/p", "tcp" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/d", "" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/n", "+1" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/n", "1_0" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/rc", "-1" }, &options, &error_buffer));
    // The diagnostic is the reference token, not prose: every case below is a measured
    // reference answer for the same command line.
    try std.testing.expectEqualStrings("invalid-number", std.mem.sliceTo(&error_buffer, 0));
    try std.testing.expect(parse(&.{ "/127.0.0.1", "/p", "tcp" }, &options, &error_buffer));
    try std.testing.expect(parse(&.{ "-1", "/p", "tcp" }, &options, &error_buffer));
}

test "client diagnostics are the reference tokens" {
    var options: client.types.Options = .{};
    var error_buffer: [client.types.error_capacity]u8 = @splat(0);
    const cases = [_]struct { argv: []const []const u8, token: []const u8 }{
        .{ .argv = &.{}, .token = "missing-target" },
        .{ .argv = &.{"127.0.0.1"}, .token = "missing-protocol" },
        .{ .argv = &.{ "/p", "tcp" }, .token = "missing-target" },
        .{ .argv = &.{ "127.0.0.1", "127.0.0.2", "/p", "tcp" }, .token = "unexpected-target" },
        .{ .argv = &.{ "/c", "1", "/threads", "2", "/p", "tcp" }, .token = "out-of-range" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/d", "x", "/z", "8" }, .token = "conflicting-payload" },
        .{ .argv = &.{ "127.0.0.1", "/p", "udp", "/k", "1" }, .token = "protocol-option" },
        .{ .argv = &.{ "127.0.0.1", "/k", "1", "/p", "udp" }, .token = "protocol-option" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/l", "7000", "/c", "2" }, .token = "local-port-conflict" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/l", "7000", "/rc", "1" }, .token = "local-port-conflict" },
        .{ .argv = &.{ "127.0.0.1", "/p", "udp", "/z", "65508" }, .token = "payload-size" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/k", "65536", "/z", "65536" }, .token = "payload-size" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/n", "18446744073709551615", "/c", "1048576" }, .token = "quota-overflow" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/c", "200", "/threads", "4", "/cq", "64" }, .token = "cq-capacity" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/k", "2", "/z", "300000", "/memory", "1048576" }, .token = "memory-capacity" },
        .{ .argv = &.{ "127.0.0.1", "/p", "sctp" }, .token = "out-of-range" },
        .{ .argv = &.{"/q=1"}, .token = "unexpected-value" },
        .{ .argv = &.{"/r="}, .token = "missing-value" },
        .{ .argv = &.{"/r"}, .token = "missing-value" },
        .{ .argv = &.{"/zzz"}, .token = "unknown-switch" },
        .{ .argv = &.{ "127.0.0.1", "/p", "tcp", "/cq", "63" }, .token = "out-of-range" },
        // The help switch suppresses only the mandatory arguments; the budgets still apply.
        .{ .argv = &.{ "/h", "/p", "tcp", "/c", "200", "/threads", "4", "/cq", "64" }, .token = "cq-capacity" },
        .{ .argv = &.{ "/h", "/d", "x", "/z", "8" }, .token = "conflicting-payload" },
    };
    for (cases) |case| {
        try std.testing.expect(!parse(case.argv, &options, &error_buffer));
        try std.testing.expectEqualStrings(case.token, std.mem.sliceTo(&error_buffer, 0));
    }
    try std.testing.expect(parse(&.{ "/h", "/p", "tcp", "/n", "1", "/d", "x" }, &options, &error_buffer));
}

test "client accepts every explicit zero the reference accepts" {
    var options: client.types.Options = .{};
    var error_buffer: [client.types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "127.0.0.1", "/p", "tcp", "/threads", "0", "/w", "0", "/report", "0", "/i", "0", "/n", "0" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u32, 0), options.worker_count);
    try std.testing.expectEqual(@as(u32, 0), options.run_seconds);
    try std.testing.expectEqual(@as(u32, 0), options.report_seconds);
    try std.testing.expectEqual(@as(u32, 0), options.interval_milliseconds);
    try std.testing.expectEqual(@as(u64, 0), options.echo_count);
    // Zero means "automatic", so the resolution rule still has to produce a worker.
    try std.testing.expectEqual(@as(u64, 3), client.types.resolvedWorkerCount(0, 3));
    try std.testing.expectEqual(@as(u64, 1), client.types.resolvedWorkerCount(0, 0));
    try std.testing.expectEqual(@as(u64, 64), client.types.resolvedWorkerCount(0, 4096));
    // An explicit reconnect delay of zero means "reconnect immediately", so it must stay enabled.
    try std.testing.expect(parse(&.{ "127.0.0.1", "/p", "tcp", "/rc", "0" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(?u32, 0), options.reconnect_seconds);
    try std.testing.expect(options.reconnectEnabled());
    // A bare reconnect switch means one second.
    try std.testing.expect(parse(&.{ "127.0.0.1", "/p", "tcp", "/rc" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(?u32, 1), options.reconnect_seconds);
}

test "client rejects lone surrogates as invalid UTF-16" {
    var options: client.types.Options = .{};
    var error_buffer: [client.types.error_capacity]u8 = @splat(0);
    // WTF-8 encodes an unpaired surrogate half as ED A0-BF xx; a valid pair is always four bytes,
    // so this sequence can only ever be a lone surrogate.
    const lone = [_]u8{ 0xED, 0xA0, 0x80 };
    try std.testing.expect(!parse(&.{ &lone, "/p", "tcp" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("invalid-utf16", std.mem.sliceTo(&error_buffer, 0));
    // Inside a payload switch the token is diagnosed after the cross-field rules, exactly like the
    // reference, but it is still the same token.
    try std.testing.expect(!parse(&.{ "127.0.0.1", "/p", "tcp", "/d", &lone }, &options, &error_buffer));
    try std.testing.expectEqualStrings("invalid-utf16", std.mem.sliceTo(&error_buffer, 0));
    // A well-formed pair is not a lone surrogate and stays accepted.
    const pair = [_]u8{ 0xF0, 0x9F, 0x98, 0x80 };
    try std.testing.expect(parse(&.{ "127.0.0.1", "/p", "tcp", "/d", &pair }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u16, 2), options.literal_len);
}

test "client strict UTF-16 payload conversion rejects surrogate halves" {
    const allocator = std.heap.page_allocator;
    var options: client.types.Options = .{ .pattern_kind = .literal_text, .literal_len = 1 };
    options.literal_pattern[0] = 0xd800;
    try std.testing.expect(client.payload.build(allocator, &options) == null);
    options = .{};
    options.host[0] = 0xd800;
    options.host_len = 1;
    try std.testing.expect(client.payload.build(allocator, &options) == null);
}

test "client payload generation matches the reference records and wrap" {
    var printable: [18]u8 = undefined;
    client.payload.fillPrintable(&printable);
    try std.testing.expectEqualStrings("00000000 00000001 ", &printable);
    var binary: [257]u8 = undefined;
    client.payload.fillBinary(&binary);
    try std.testing.expectEqual(@as(u8, 255), binary[255]);
    try std.testing.expectEqual(@as(u8, 0), binary[256]);
    // A window that is not a whole number of payloads still repeats the payload from its start.
    var window: [7]u8 = undefined;
    client.payload.fillRepeated(&window, "abc");
    try std.testing.expectEqualStrings("abcabca", &window);
}

test "client per-session quota is trimmed and never refunded" {
    var claimed: u64 = 0;
    try std.testing.expectEqual(@as(u64, 8), client.scheduler.claimSessionAttempts(&claimed, 17, 8));
    try std.testing.expectEqual(@as(u64, 8), client.scheduler.claimSessionAttempts(&claimed, 17, 8));
    try std.testing.expectEqual(@as(u64, 1), client.scheduler.claimSessionAttempts(&claimed, 17, 8));
    try std.testing.expectEqual(@as(u64, 0), client.scheduler.claimSessionAttempts(&claimed, 17, 8));
    try std.testing.expectEqual(@as(u64, 17), claimed);
    try std.testing.expectEqual(@as(u64, 2), client.contract.unclaimedEchoes(5, 3, false));
    try std.testing.expectEqual(@as(u64, 0), client.contract.unclaimedEchoes(5, 3, true));
    try std.testing.expect(client.contract.percentileTarget(std.math.maxInt(u64), 999, 1000) != 0);
}

test "client storage and result classification retain the reference boundaries" {
    try std.testing.expectEqual(@as(?u64, 262144), client.contract.checkedStorageBytes(32, 4096, 1048576));
    try std.testing.expect(client.contract.checkedStorageBytes(32, 4096, 131072) == null);
    try std.testing.expectEqual(@as(u8, 0), client.contract.classifyResult(10, 0, 0, 2, false, false));
    try std.testing.expectEqual(@as(u8, 2), client.contract.classifyResult(0, 0, 0, 2, false, false));
    try std.testing.expectEqual(@as(u8, 3), client.contract.classifyResult(9, 0, 1, 1, false, false));
    try std.testing.expectEqual(@as(u8, 4), client.contract.classifyResult(10, 0, 0, 0, true, false));
    // A controlled stop is a success even when nothing echoed, because nothing was required to.
    try std.testing.expectEqual(@as(u8, 0), client.contract.classifyResult(0, 0, 0, 2, false, true));
}
