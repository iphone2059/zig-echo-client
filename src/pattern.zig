const std = @import("std");

pub fn fillBinary(output: []u8) void {
    for (output, 0..) |*byte, i| byte.* = @truncate(i);
}

pub fn fillPrintable(output: []u8) void {
    for (output, 0..) |*byte, index| {
        const record_offset = index % 9;
        if (record_offset == 8) {
            byte.* = ' ';
            continue;
        }
        const record = index / 9;
        var divisor: usize = 10_000_000;
        for (0..record_offset) |_| divisor /= 10;
        byte.* = @intCast('0' + (record / divisor) % 10);
    }
}

pub fn fillRepeated(destination: []u8, pattern: []const u8) void {
    if (pattern.len == 0) return;
    var offset: usize = 0;
    while (offset < destination.len) {
        const n = @min(pattern.len, destination.len - offset);
        @memcpy(destination[offset .. offset + n], pattern[0..n]);
        offset += n;
    }
}

test "patterns" {
    var a: [260]u8 = undefined;
    fillBinary(&a);
    try std.testing.expectEqual(@as(u8, 0), a[0]);
    try std.testing.expectEqual(@as(u8, 255), a[255]);
    try std.testing.expectEqual(@as(u8, 0), a[256]);
    var b: [100]u8 = undefined;
    fillPrintable(&b);
    for (b) |ch| try std.testing.expect(ch >= 32 and ch <= 126);
}
