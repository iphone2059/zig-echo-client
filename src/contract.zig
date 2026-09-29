const std = @import("std");

pub fn checkedProduct(left: usize, right: usize) ?usize {
    const pair = @mulWithOverflow(left, right);
    if (pair[1] != 0) return null;
    return pair[0];
}

pub fn checkedStorageBytes(sessions: usize, batch_bytes: usize, memory_limit: u64) ?usize {
    const per_session = checkedProduct(batch_bytes, 2) orelse return null;
    const total = checkedProduct(sessions, per_session) orelse return null;
    if (total > memory_limit) return null;
    return total;
}

pub fn claimAttempts(claimed: *std.atomic.Value(u64), limit: u64, requested: u64) u64 {
    if (requested == 0) return 0;
    if (limit == 0) {
        _ = claimed.fetchAdd(requested, .monotonic);
        return requested;
    }
    var observed = claimed.load(.monotonic);
    while (true) {
        if (observed >= limit) return 0;
        const granted = @min(requested, limit - observed);
        if (claimed.cmpxchgWeak(observed, observed + granted, .monotonic, .monotonic)) |actual| {
            observed = actual;
        } else return granted;
    }
}

pub fn unclaimedEchoes(limit: u64, claimed: u64, controlled_stop: bool) u64 {
    if (controlled_stop or limit == 0 or claimed >= limit) return 0;
    return limit - claimed;
}

pub fn percentileTarget(total: u64, numerator: u64, denominator: u64) u64 {
    if (total == 0 or numerator == 0 or denominator == 0 or numerator > denominator) return 0;
    const q = total / denominator;
    const r = total % denominator;
    return q * numerator + (r * numerator + denominator - 1) / denominator;
}

pub fn classifyResult(echoed: u64, corrupted: u64, lost: u64, network_errors: u64, fatal: bool, controlled_stop: bool) u8 {
    _ = network_errors;
    if (fatal) return 4;
    if (corrupted != 0 or lost != 0) return 3;
    if (controlled_stop) return 0;
    if (echoed == 0) return 2;
    return 0;
}

pub fn notificationMarkDelivered(armed: *bool) bool {
    if (!armed.*) return false;
    armed.* = false;
    return true;
}

pub fn notificationMarkRearmed(armed: *bool) bool {
    if (armed.*) return false;
    armed.* = true;
    return true;
}

test "claim finite attempts" {
    var claimed = std.atomic.Value(u64).init(0);
    try std.testing.expectEqual(@as(u64, 4), claimAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 1), claimAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 0), claimAttempts(&claimed, 5, 4));
}

test "storage accounting" {
    try std.testing.expectEqual(@as(?usize, 800), checkedStorageBytes(4, 100, 800));
    try std.testing.expect(checkedStorageBytes(4, 100, 799) == null);
}

test "unclaimed and result classification" {
    try std.testing.expectEqual(@as(u64, 2), unclaimedEchoes(5, 3, false));
    try std.testing.expectEqual(@as(u64, 0), unclaimedEchoes(5, 3, true));
    try std.testing.expectEqual(@as(u8, 0), classifyResult(5, 0, 0, 0, false, false));
    try std.testing.expectEqual(@as(u8, 2), classifyResult(0, 0, 0, 1, false, false));
    try std.testing.expectEqual(@as(u8, 3), classifyResult(4, 1, 0, 0, false, false));
    try std.testing.expectEqual(@as(u8, 4), classifyResult(0, 0, 0, 0, true, false));
}
