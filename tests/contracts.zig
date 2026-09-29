const std = @import("std");
const client = @import("client");

fn parse(argv: []const []const u8, out: *client.types.Options, error_buffer: []u8) bool {
    return client.options.parseArgs(argv, out, error_buffer);
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
    try std.testing.expect(!parse(&.{ &.{ 0xff }, "/p", "tcp" }, &options, &error_buffer));
}

test "client payload generation matches C++ records and wrap" {
    var printable: [18]u8 = undefined;
    client.pattern.fillPrintable(&printable);
    try std.testing.expectEqualStrings("00000000 00000001 ", &printable);
    var binary: [257]u8 = undefined;
    client.pattern.fillBinary(&binary);
    try std.testing.expectEqual(@as(u8, 255), binary[255]);
    try std.testing.expectEqual(@as(u8, 0), binary[256]);
}

test "client atomic claims remain exact across finite partial batches" {
    var claimed = std.atomic.Value(u64).init(0);
    try std.testing.expectEqual(@as(u64, 3), client.contract.claimAttempts(&claimed, 3, 8));
    try std.testing.expectEqual(@as(u64, 0), client.contract.claimAttempts(&claimed, 3, 8));
    try std.testing.expectEqual(@as(u64, 3), claimed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), client.contract.unclaimedEchoes(5, 3, false));
    try std.testing.expect(client.contract.percentileTarget(std.math.maxInt(u64), 999, 1000) != 0);
}

test "client storage and result classification retain C++ boundaries" {
    try std.testing.expectEqual(@as(?usize, 262144), client.contract.checkedStorageBytes(32, 4096, 1048576));
    try std.testing.expect(client.contract.checkedStorageBytes(32, 4096, 131072) == null);
    try std.testing.expectEqual(@as(u8, 0), client.contract.classifyResult(10, 0, 0, 2, false, false));
    try std.testing.expectEqual(@as(u8, 2), client.contract.classifyResult(0, 0, 0, 2, false, false));
    try std.testing.expectEqual(@as(u8, 3), client.contract.classifyResult(9, 0, 1, 1, false, false));
    try std.testing.expectEqual(@as(u8, 4), client.contract.classifyResult(10, 0, 0, 0, true, false));
}
