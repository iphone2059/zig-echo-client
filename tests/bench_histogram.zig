const std = @import("std");
const Histogram = @import("client").bench_histogram.Histogram;

test "one microsecond and powers of two remain distinct" {
    var histogram = Histogram.init();
    histogram.record(1);
    histogram.record(2);
    histogram.record(64);
    try std.testing.expectEqual(@as(u64, 3), histogram.count);
    try std.testing.expectEqual(@as(u64, 1), histogram.percentile(1, 3));
    try std.testing.expectEqual(@as(u64, 2), histogram.percentile(2, 3));
    try std.testing.expectEqual(@as(u64, 64), histogram.percentile(1, 1));
}

test "nearby values in a power-of-two band use distinct sub-buckets" {
    var histogram = Histogram.init();
    histogram.record(64);
    histogram.record(65);
    histogram.record(127);
    histogram.record(128);
    try std.testing.expectEqual(@as(u64, 64), histogram.percentile(1, 4));
    try std.testing.expectEqual(@as(u64, 65), histogram.percentile(2, 4));
    try std.testing.expectEqual(@as(u64, 127), histogram.percentile(3, 4));
    try std.testing.expectEqual(@as(u64, 128), histogram.percentile(1, 1));
}

test "zero and saturated maximum are bounded" {
    var histogram = Histogram.init();
    histogram.record(0);
    histogram.record(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 1), histogram.percentile(1, 2));
    try std.testing.expectEqual(std.math.maxInt(u64), histogram.percentile(1, 1));
}

test "percentile ranks use ceiling and one sample per completed batch" {
    var histogram = Histogram.init();
    for (0..1000) |i| histogram.record(@intCast(i + 1));
    try std.testing.expectEqual(@as(u64, 1000), histogram.count);
    try std.testing.expect(histogram.percentile(50, 100) >= 490);
    try std.testing.expect(histogram.percentile(99, 100) >= 980);
    try std.testing.expect(histogram.percentile(999, 1000) >= 989);
    try std.testing.expect(histogram.percentile(50, 100) < histogram.percentile(99, 100));
    try std.testing.expect(histogram.percentile(99, 100) <= histogram.percentile(999, 1000));
}
