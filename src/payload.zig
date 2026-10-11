//! Echo payload construction and byte-exact verification.
//!
//! The bytes here are what a peer sees, so the counter patterns reproduce the reference's exact
//! sequences rather than merely looking readable.

const std = @import("std");
const types = @import("types.zig");

/// The default payload of the baseline: the literal text below, sent as ASCII.
pub const default_text_prefix = "echo from ";

/// Deterministic counter: byte i holds i as u8, so the sequence wraps every 256 bytes.
pub fn fillBinary(output: []u8) void {
    for (output, 0..) |*byte, index| byte.* = @truncate(index);
}

/// Printable counter: a stream of nine-byte records. Each record is eight decimal digits holding
/// the record number, followed by a space, so a nine-byte request is "00000000 " and an
/// eighteen-byte request is "00000000 00000001 ".
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

/// Repeats the payload across a registered TX window so the whole window is deterministic: a
/// partial send that is re-posted from an arbitrary offset still echoes the same sequence.
pub fn fillRepeated(destination: []u8, pattern: []const u8) void {
    if (pattern.len == 0) return;
    var offset: usize = 0;
    while (offset < destination.len) {
        const amount = @min(pattern.len, destination.len - offset);
        @memcpy(destination[offset .. offset + amount], pattern[0..amount]);
        offset += amount;
    }
}

/// Builds the payload for a session. Sizes are validated here as well as in the parser so a caller
/// that builds options by hand cannot smuggle an impossible payload in.
pub fn build(allocator: std.mem.Allocator, options: *const types.Options) ?[]u8 {
    return switch (options.pattern_kind) {
        .binary_counter => counter(allocator, options.pattern_bytes, fillBinary),
        .printable_counter => counter(allocator, options.pattern_bytes, fillPrintable),
        .literal_text => std.unicode.utf16LeToUtf8Alloc(allocator, options.literalUtf16()) catch null,
        .default_text => defaultText(allocator, options),
    };
}

fn counter(allocator: std.mem.Allocator, length: u32, fill: *const fn ([]u8) void) ?[]u8 {
    if (length == 0) return null;
    const bytes = allocator.alloc(u8, length) catch return null;
    fill(bytes);
    return bytes;
}

fn defaultText(allocator: std.mem.Allocator, options: *const types.Options) ?[]u8 {
    const host = std.unicode.utf16LeToUtf8Alloc(allocator, options.hostUtf16()) catch return null;
    defer allocator.free(host);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ default_text_prefix, host }) catch null;
}

/// The transport limit that applies to one payload, before any session is created.
pub fn limit(options: *const types.Options) u64 {
    return if (options.protocol == .udp) types.maximum_udp_payload else types.maximum_tcp_batch_bytes;
}

pub fn validate(options: *const types.Options, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    return bytes.len <= limit(options);
}

/// Exact comparison: an echo is only accepted when every byte matches. A short read is a failure,
/// never a partial success.
pub fn verify(echoed: []const u8, pattern: []const u8) bool {
    return echoed.len == pattern.len and std.mem.eql(u8, echoed, pattern);
}

test "counters are deterministic" {
    var binary: [260]u8 = undefined;
    fillBinary(&binary);
    try std.testing.expectEqual(@as(u8, 0), binary[0]);
    try std.testing.expectEqual(@as(u8, 255), binary[255]);
    try std.testing.expectEqual(@as(u8, 0), binary[256]);

    var printable: [18]u8 = undefined;
    fillPrintable(&printable);
    try std.testing.expectEqualStrings("00000000 00000001 ", &printable);
    for (printable) |character| try std.testing.expect(character >= 32 and character <= 126);
}

test "repetition fills the whole window" {
    var window: [10]u8 = undefined;
    fillRepeated(&window, "abc");
    try std.testing.expectEqualStrings("abcabcabca", &window);
    var untouched: [0]u8 = .{};
    fillRepeated(&untouched, "");
}

test "verification is byte exact" {
    try std.testing.expect(verify("abcd", "abcd"));
    try std.testing.expect(!verify("abc", "abcd"));
    try std.testing.expect(!verify("abce", "abcd"));
}
