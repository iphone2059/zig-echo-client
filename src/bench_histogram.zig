const std = @import("std");
const contract = @import("contract.zig");

/// Benchmark-only, worker-owned latency samples. Each record is one completed
/// I/O batch, regardless of how many logical echoes were in that batch.
pub const Histogram = struct {
    pub const bucket_count = 64 * 64;

    buckets: [bucket_count]u64 = @splat(0),
    count: u64 = 0,

    pub fn init() Histogram {
        return .{};
    }

    pub fn record(self: *Histogram, micros: u64) void {
        const value = @max(@as(u64, 1), micros);
        const band: usize = std.math.log2_int(u64, value);
        const base: u64 = @as(u64, 1) << @intCast(band);
        const offset: u64 = value - base;
        const sub: usize = @intCast(@min(@as(u128, 63), @as(u128, offset) * 64 / base));
        self.buckets[band * 64 + sub] += 1;
        self.count += 1;
    }

    pub fn percentile(self: *const Histogram, numerator: u64, denominator: u64) u64 {
        const target = contract.percentileTarget(self.count, numerator, denominator);
        if (target == 0) return 0;
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |samples, index| {
            cumulative += samples;
            if (cumulative >= target) {
                if (index == bucket_count - 1) return std.math.maxInt(u64);
                const band = index / 64;
                const sub = index % 64;
                const base: u128 = @as(u128, 1) << @intCast(band);
                return @intCast(base + base * sub / 64);
            }
        }
        unreachable;
    }
};
