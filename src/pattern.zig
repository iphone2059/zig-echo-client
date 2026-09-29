const std = @import("std");

pub fn fillBinary(output: []u8) void {
    for (output, 0..) |*byte, i| byte.* = @truncate(i);
}

pub fn fillPrintable(output: []u8) void {
    const first: usize = 32;
    const count: usize = 95;
    for (output, 0..) |*byte, i| byte.* = @intCast(first + i % count);
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
