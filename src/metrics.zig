//! Run statistics: the counters the final line reports, the latency histogram, the optional
//! benchmark histogram and the exit-code classification.
//!
//! Nothing here is shared: each worker owns one ledger and the run merges them after every worker
//! has joined, so the hot path never touches an atomic.

const std = @import("std");
const contract = @import("contract.zig");
const types = @import("types.zig");
const bench_config = @import("bench_config");

/// The reference buckets latency by the power of two below the sample, so bin i means
/// [2^i, 2^(i+1)) microseconds and the reported value is that lower bound rather than the sample.
/// Sixty-four bins cover the whole u64 range because the index is clamped.
pub const latency_buckets: usize = 64;

/// Counters accumulated by one worker.
pub const Statistics = struct {
    echoes: u64 = 0,
    sent_bytes: u64 = 0,
    received_bytes: u64 = 0,
    /// Echo bytes that were verified against the payload. The reference counts only validated
    /// echoes here, while received_bytes counts everything the socket delivered.
    bytes: u64 = 0,
    corrupted: u64 = 0,
    lost: u64 = 0,
    /// Attempts the scheduler claimed. The identity is
    /// attempted = pending + echoed + corrupted + lost + cancelled, exactly as the reference
    /// reports it.
    attempted: u64 = 0,
    /// Attempts that were claimed but never finished when the run stopped under control.
    cancelled: u64 = 0,
    connections: u64 = 0,
    reconnects: u64 = 0,
    /// Connection failures, including failed generations that will reconnect.
    network_errors: u64 = 0,
    fatal: bool = false,
    latency_bins: [latency_buckets]u64 = @splat(0),
    latency_samples: u64 = 0,
    latency_sum_us: u64 = 0,
    latency_max_us: u64 = 0,
    elapsed_ms: u64 = 0,

    pub fn merge(self: *Statistics, other: *const Statistics) void {
        self.echoes +%= other.echoes;
        self.sent_bytes +%= other.sent_bytes;
        self.received_bytes +%= other.received_bytes;
        self.bytes +%= other.bytes;
        self.corrupted +%= other.corrupted;
        self.lost +%= other.lost;
        self.attempted +%= other.attempted;
        self.cancelled +%= other.cancelled;
        self.connections +%= other.connections;
        self.reconnects +%= other.reconnects;
        self.network_errors +%= other.network_errors;
        self.fatal = self.fatal or other.fatal;
        for (&self.latency_bins, other.latency_bins) |*target, source| target.* +%= source;
        self.latency_samples +%= other.latency_samples;
        self.latency_sum_us +%= other.latency_sum_us;
        self.latency_max_us = @max(self.latency_max_us, other.latency_max_us);
        self.elapsed_ms = @max(self.elapsed_ms, other.elapsed_ms);
    }

    /// Records one completed attempt, which is one latency sample because the histogram samples
    /// batches rather than echoes. Zero and sub-microsecond samples count as one microsecond,
    /// matching the reference's tick conversion.
    pub fn recordLatency(self: *Statistics, micros: u64) void {
        const value = @max(@as(u64, 1), micros);
        self.latency_samples +%= 1;
        self.latency_sum_us +%= value;
        self.latency_max_us = @max(self.latency_max_us, value);
        const band: usize = 63 - @as(usize, @clz(value));
        self.latency_bins[@min(band, latency_buckets - 1)] +%= 1;
    }

    pub fn sampleCount(self: *const Statistics) u64 {
        var total: u64 = 0;
        for (self.latency_bins) |count| total +%= count;
        return total;
    }

    /// Percentile from the histogram: the lower bound of the first bucket that crosses the
    /// requested fraction of samples, which is what the reference's approximate marker means.
    pub fn percentile(self: *const Statistics, numerator: u64, denominator: u64) u64 {
        const total = self.sampleCount();
        if (total == 0 or numerator == 0 or denominator == 0 or numerator > denominator) return 0;
        const target = contract.percentileTarget(total, numerator, denominator);
        if (target == 0) return 0;
        var seen: u64 = 0;
        for (self.latency_bins, 0..) |count, index| {
            seen +%= count;
            if (seen >= target) return @as(u64, 1) << @intCast(@min(index, 63));
        }
        return 0;
    }

    pub fn meanLatencyUs(self: *const Statistics) u64 {
        if (self.latency_samples == 0) return 0;
        return self.latency_sum_us / self.latency_samples;
    }

    pub fn echoPerSecond(self: *const Statistics) f64 {
        return @as(f64, @floatFromInt(self.echoes)) * 1_000.0 /
            @as(f64, @floatFromInt(@max(self.elapsed_ms, 1)));
    }

    pub fn mibPerSecond(self: *const Statistics) f64 {
        const mib = @as(f64, @floatFromInt(self.bytes)) / (1024.0 * 1024.0);
        return mib * 1_000.0 / @as(f64, @floatFromInt(@max(self.elapsed_ms, 1)));
    }

    pub fn terminalCount(self: *const Statistics) u64 {
        var total: u64 = 0;
        total +%= self.echoes;
        total +%= self.corrupted;
        total +%= self.lost;
        total +%= self.cancelled;
        return total;
    }

    /// Pending is derived, because an attempt is pending exactly while it has been claimed and has
    /// not reached a terminal state.
    pub fn pending(self: *const Statistics) u64 {
        return self.attempted -| self.terminalCount();
    }

    /// Echoes that were asked for but never claimed. The quota switch is a per-session quota, so
    /// the run the command line describes is that many times the session count. A controlled stop
    /// is not a loss.
    pub fn unclaimed(self: *const Statistics, limit: u64, sessions: u32, controlled_stop: bool) u64 {
        return contract.unclaimedEchoes(limit *| @as(u64, sessions), self.attempted, controlled_stop);
    }

    pub fn exitCode(self: *const Statistics, controlled_stop: bool) types.ExitCode {
        return @fromBackingInt(contract.classifyResult(
            self.echoes,
            self.corrupted,
            self.lost,
            self.network_errors,
            self.fatal,
            controlled_stop,
        ));
    }

    /// The terminal line. Its fields, their order and their separators are the baseline's, so a run
    /// can be compared across implementations by reading the line alone.
    pub fn writeLine(
        self: *const Statistics,
        label: []const u8,
        sessions: u32,
        active: u32,
        buffer: []u8,
    ) ?[]const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{s} elapsed_ms={d} sessions={d} active={d} attempted={d} pending={d} echoed={d} corrupted={d} lost={d} cancelled={d} sent_bytes={d} received_bytes={d} bytes={d} connections={d} reconnects={d} network_errors={d} echo_per_sec={d:.2} MiB_per_sec={d:.2} p50_us~{d} p99_us~{d} p999_us~{d} mean_us={d} max_us~{d} latency_sample=batch\n",
            .{
                label,
                self.elapsed_ms,
                sessions,
                active,
                self.attempted,
                self.pending(),
                self.echoes,
                self.corrupted,
                self.lost,
                self.cancelled,
                self.sent_bytes,
                self.received_bytes,
                self.bytes,
                self.connections,
                self.reconnects,
                self.network_errors,
                self.echoPerSecond(),
                self.mibPerSecond(),
                self.percentile(50, 100),
                self.percentile(99, 100),
                self.percentile(999, 1_000),
                self.meanLatencyUs(),
                // The reference reports the maximum as the same histogram percentile, so this field
                // is a bucket lower bound like the others rather than the exact maximum observed.
                self.percentile(1, 1),
            },
        ) catch null;
    }
};

/// Benchmark-only, worker-owned latency samples. Each record is one completed I/O batch,
/// regardless of how many logical echoes were in that batch.
pub const Histogram = struct {
    pub const bucket_count = 64 * 64;

    buckets: [bucket_count]u64 = @splat(0),
    count: u64 = 0,

    pub fn record(self: *Histogram, micros: u64) void {
        const value = @max(@as(u64, 1), micros);
        const band: usize = 63 - @as(usize, @clz(value));
        const base: u64 = @as(u64, 1) << @intCast(band);
        const offset: u64 = value - base;
        const sub: usize = @intCast(@min(@as(u128, 63), @as(u128, offset) * 64 / base));
        self.buckets[band * 64 + sub] +|= 1;
        self.count +|= 1;
    }

    pub fn percentile(self: *const Histogram, numerator: u64, denominator: u64) u64 {
        const target = contract.percentileTarget(self.count, numerator, denominator);
        if (target == 0) return 0;
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |samples, index| {
            cumulative +|= samples;
            if (cumulative >= target) {
                if (index == bucket_count - 1) return std.math.maxInt(u64);
                const band = index / 64;
                const sub = index % 64;
                const base: u128 = @as(u128, 1) << @intCast(band);
                return @intCast(base + base * sub / 64);
            }
        }
        return 0;
    }
};

/// The worker's optional benchmark histogram. When the build option is off the field becomes
/// void, so the record call and the 32 KiB of buckets disappear from the hot path entirely.
pub const benchmark_enabled = bench_config.enabled;
pub const WorkerHistogram = if (benchmark_enabled) Histogram else void;

test "latency buckets follow the reference" {
    var statistics = Statistics{};
    statistics.recordLatency(0);
    statistics.recordLatency(1);
    try std.testing.expectEqual(@as(u64, 2), statistics.latency_bins[0]);
    statistics.recordLatency(1_024);
    try std.testing.expectEqual(@as(u64, 1), statistics.latency_bins[10]);
    try std.testing.expectEqual(@as(u64, 3), statistics.sampleCount());
    // Two samples in the one-microsecond bin, one in the 1024-microsecond bin: the median is still
    // the lower bin, and the whole-sample percentile reaches the upper one.
    try std.testing.expectEqual(@as(u64, 1), statistics.percentile(2, 3));
    try std.testing.expectEqual(@as(u64, 1_024), statistics.percentile(1, 1));
    // A fraction whose ceiling is one sample still lands in the lowest populated bucket.
    try std.testing.expectEqual(@as(u64, 1), statistics.percentile(29, 100));
}

test "the ledger identity holds" {
    var statistics = Statistics{};
    statistics.attempted = 10;
    statistics.echoes = 6;
    statistics.corrupted = 1;
    try std.testing.expectEqual(@as(u64, 3), statistics.pending());
    statistics.cancelled = 3;
    try std.testing.expectEqual(@as(u64, 0), statistics.pending());
    // The quota switch is a per-session quota, so five per session over four sessions is a run of
    // twenty; ten of those were claimed, and a controlled stop forfeits the rest.
    try std.testing.expectEqual(@as(u64, 10), statistics.unclaimed(5, 4, false));
    try std.testing.expectEqual(@as(u64, 0), statistics.unclaimed(5, 4, true));
}
