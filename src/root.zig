//! Windows x64 RIO echo client core.
//!
//! The module tree mirrors the Rust client file for file: contract (command line and capacity
//! budgets) -> native (Winsock, RIO, ConnectEx and every resource owner) -> engine (native data
//! path, worker start and stop, run coordination) -> internal (session, scheduler, worker, timer)
//! -> main (entry point). metrics, payload and types are leaf modules with no dependency on the
//! state machines, so the graph has no cycle and native never depends on internal.

const std = @import("std");

pub const contract = @import("contract.zig");
pub const engine = @import("engine.zig");
pub const internal = @import("internal.zig");
pub const metrics = @import("metrics.zig");
pub const native = @import("native.zig");
pub const payload = @import("payload.zig");
pub const types = @import("types.zig");

/// The names the state machines are reached by, re-exported so a test never has to spell out the
/// two-level path and so the shape of internal stays free to change.
pub const session = internal.session;
pub const scheduler = internal.session.scheduler;
pub const worker = internal.worker;
pub const timer = internal.timer;
pub const trace = internal.worker.trace;

test {
    _ = contract;
    _ = engine;
    _ = internal;
    _ = metrics;
    _ = native;
    _ = payload;
    _ = types;
}
