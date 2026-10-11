//! Client state machines: the session ledger, the scheduler decisions, the fixed-capacity timer
//! heap and the worker record that owns them.
//!
//! This file issues no native call. The native data path, the worker start and stop sequence and the
//! run coordination live in engine.zig, which is what keeps the dependency direction one-way:
//! internal depends on native, and native never depends on internal.
//!
//! Reference implementation: the reference's cec_engine_internal.cpp, mirrored by the Rust client's
//! internal module. Business state and timers only; native object lifetime belongs to the engine.

const std = @import("std");
const builtin = @import("builtin");
const metrics = @import("metrics.zig");
const native = @import("native.zig");
const types = @import("types.zig");

const c = native.sdk.c;

/// A fixed-capacity indexed binary min-heap over absolute deadlines, in clock ticks.
///
/// The heap owns no memory: its nodes and the index-to-position map are allocated once when the
/// worker starts, so arming, re-arming and expiring a session never allocate.
pub const timer = struct {
    pub const invalid_position: u32 = std.math.maxInt(u32);

    pub const Node = struct {
        deadline: u64 = 0,
        index: u32 = 0,
    };

    pub const Heap = struct {
        nodes: []Node = &.{},
        positions: []u32 = &.{},
        len: u32 = 0,

        pub fn init(nodes: []Node, positions: []u32) !Heap {
            if (nodes.len == 0 or nodes.len != positions.len or nodes.len > std.math.maxInt(u32)) return error.InvalidCapacity;
            @memset(positions, invalid_position);
            return .{ .nodes = nodes, .positions = positions };
        }

        /// Ties break on the session index, so equal deadlines still expire in a deterministic
        /// order and a deadline test is reproducible.
        fn less(a: Node, b: Node) bool {
            return a.deadline < b.deadline or (a.deadline == b.deadline and a.index < b.index);
        }

        fn swap(self: *Heap, a: u32, b: u32) void {
            std.mem.swap(Node, &self.nodes[a], &self.nodes[b]);
            self.positions[self.nodes[a].index] = a;
            self.positions[self.nodes[b].index] = b;
        }

        fn siftUp(self: *Heap, start: u32) void {
            var position = start;
            while (position != 0) {
                const parent = (position - 1) / 2;
                if (!less(self.nodes[position], self.nodes[parent])) break;
                self.swap(position, parent);
                position = parent;
            }
        }

        fn siftDown(self: *Heap, start: u32) void {
            var position = start;
            while (true) {
                const left = position * 2 + 1;
                if (left >= self.len) break;
                var best = left;
                const right = left + 1;
                if (right < self.len and less(self.nodes[right], self.nodes[left])) best = right;
                if (!less(self.nodes[best], self.nodes[position])) break;
                self.swap(position, best);
                position = best;
            }
        }

        pub fn insertOrUpdate(self: *Heap, index: u32, deadline: u64) bool {
            if (index >= self.positions.len) return false;
            const position = self.positions[index];
            if (position == invalid_position) {
                if (self.len >= self.nodes.len) return false;
                const slot = self.len;
                self.len += 1;
                self.nodes[slot] = .{ .deadline = deadline, .index = index };
                self.positions[index] = slot;
                self.siftUp(slot);
                return true;
            }
            const previous = self.nodes[position].deadline;
            self.nodes[position].deadline = deadline;
            if (deadline < previous) self.siftUp(position) else self.siftDown(position);
            return true;
        }

        pub fn remove(self: *Heap, index: u32) bool {
            if (index >= self.positions.len) return false;
            const position = self.positions[index];
            if (position == invalid_position) return false;
            self.positions[index] = invalid_position;
            self.len -= 1;
            if (position == self.len) return true;
            self.nodes[position] = self.nodes[self.len];
            self.positions[self.nodes[position].index] = position;
            if (position != 0 and less(self.nodes[position], self.nodes[(position - 1) / 2])) {
                self.siftUp(position);
            } else {
                self.siftDown(position);
            }
            return true;
        }

        pub fn popExpired(self: *Heap, now: u64) ?u32 {
            if (self.len == 0 or self.nodes[0].deadline > now) return null;
            const index = self.nodes[0].index;
            _ = self.remove(index);
            return index;
        }

        /// Ticks until the earliest arming, clamped to the caller's maximum. An empty heap waits
        /// for the maximum, which is what lets a stop packet or a run deadline break the wait.
        pub fn waitTicks(self: *const Heap, now: u64, maximum: u64) u64 {
            if (self.len == 0) return maximum;
            const deadline = self.nodes[0].deadline;
            if (deadline <= now) return 0;
            return @min(deadline - now, maximum);
        }
    };
};

/// Steps one session may need at once: a connect, a receive and a send.
pub const steps_per_session: usize = 3;

/// The deepest decision recursion: start -> connect -> post failure -> close -> drained.
pub const step_levels: u32 = 5;

/// How long a retiring generation may take before the run is declared broken. Cancellation
/// completion is normally prompt; a provider that never delivers one must not strand the worker in
/// Closing forever.
pub const drain_grace_milliseconds: u64 = 5_000;

/// The size of one step region, which is what one scheduler decision may emit.
pub fn stepRegionBytes(session_count: u32) usize {
    return @as(usize, session_count) * steps_per_session;
}

pub const session = struct {
    /// Protocol state of one session.
    ///
    /// Closing means the scheduler is waiting for the transport to retire every outstanding native
    /// operation of the current generation. Only then may a reconnect be scheduled, because a new
    /// socket must never be created while the old generation can still produce completions.
    pub const State = enum(u8) { dormant, connecting, active, pacing, reconnecting, closing, done };

    pub const Session = struct {
        index: u32 = 0,
        state: State = .dormant,
        /// Bumped for every new transport generation. It is carried in every request context, so a
        /// completion belonging to a retired generation can never steer the live state machine.
        generation: u32 = 0,
        /// Set while this session counts towards the report's active total.
        active_counted: bool = false,
        /// Echo units the per-session quota has granted this session.
        claimed: u64 = 0,
        /// Echo units carried by the attempt currently in flight; zero when none is posted.
        requested_echoes: u64 = 0,
        /// Echo units this session already settled as echoed, corrupted or lost. The ledger is
        /// claimed = requested + settled + inflight, which is what lets a reconnect keep the quota
        /// a failed attempt already spent instead of handing it back.
        settled: u64 = 0,
        attempt_bytes: usize = 0,
        send_offset: usize = 0,
        received_bytes: usize = 0,
        deadline_ticks: u64 = 0,
        send_at_ticks: u64 = 0,
        reconnect_at_ticks: u64 = 0,
        attempt_started_ticks: u64 = 0,
        send_done: bool = false,
        receive_done: bool = false,
        attempt_accounted: bool = false,
        reconnect_after_close: bool = false,

        pub fn isFinished(self: *const Session) bool {
            return self.state == .done;
        }
    };

    /// The scheduler owns business state only. Native generation lifetime belongs to the engine and
    /// reconnect is deliberately split in two phases: a failure emits a close, and the drain event
    /// after every outstanding operation retired arms the reconnect timer.
    pub const scheduler = struct {
        pub const Step = union(enum) {
            connect: u32,
            send: struct { index: u32, bytes: u32 },
            receive: struct { index: u32, bytes: u32 },
            close: u32,
        };

        /// The first attempt of a transport generation is immediate; the interval spaces only later
        /// cycles, matching the baseline behaviour.
        pub fn start(wrk: *worker.Worker, now: u64, out: []Step) []const Step {
            var count: usize = 0;
            for (wrk.sessions) |*entry| {
                if (entry.state != .dormant) continue;
                entry.state = .connecting;
                entry.received_bytes = 0;
                entry.send_at_ticks = 0;
                entry.reconnect_at_ticks = 0;
                entry.deadline_ticks = now +| wrk.timeout_ticks;
                count += wrk.emit(out, count, .{ .connect = entry.index });
                wrk.armTimer(entry.index, entry.deadline_ticks);
            }
            return out[0..count];
        }

        /// Step construction can precede expensive socket preparation. The engine refreshes this
        /// provisional deadline at the native posting boundary, so an earlier session cannot consume
        /// a later session's timeout.
        pub fn anchorPostedTimeout(wrk: *worker.Worker, index: u32, now: u64) void {
            if (index >= wrk.sessions.len) {
                wrk.markFatal();
                return;
            }
            const entry = &wrk.sessions[index];
            if (entry.state != .connecting and entry.state != .active) return;
            entry.deadline_ticks = now +| wrk.timeout_ticks;
            wrk.armTimer(index, entry.deadline_ticks);
        }

        /// Everything that became due: an expired deadline fails the attempt, a pacing timer starts
        /// the next attempt, and a reconnect timer opens a new transport generation.
        pub fn poll(wrk: *worker.Worker, now: u64, out: []Step) []const Step {
            var count: usize = 0;
            while (wrk.timers.popExpired(now)) |index| {
                if (index >= wrk.sessions.len) {
                    wrk.markFatal();
                    return out[0..count];
                }
                const entry = &wrk.sessions[index];
                switch (entry.state) {
                    .connecting, .active => count += fail(wrk, entry, now, out, count),
                    .closing => {
                        // The grace expired: the generation never drained, so no further progress is
                        // possible and the terminal accounting must not claim a clean stop.
                        wrk.markFatal();
                    },
                    .pacing => count += beginAttempt(wrk, entry, now, out, count),
                    .reconnecting => {
                        entry.generation = native.completion.nextGeneration(entry.generation);
                        entry.state = .connecting;
                        entry.received_bytes = 0;
                        entry.send_at_ticks = 0;
                        entry.reconnect_at_ticks = 0;
                        count += wrk.emit(out, count, .{ .connect = index });
                        entry.deadline_ticks = now +| wrk.timeout_ticks;
                        wrk.armTimer(index, entry.deadline_ticks);
                    },
                    else => {},
                }
            }
            return out[0..count];
        }

        /// A successful connect establishes the generation and starts the first attempt.
        pub fn onConnected(wrk: *worker.Worker, index: u32, now: u64, out: []Step) []const Step {
            if (index >= wrk.sessions.len) {
                wrk.markFatal();
                return out[0..0];
            }
            const entry = &wrk.sessions[index];
            if (entry.state != .connecting) return out[0..0];
            entry.state = .active;
            entry.active_counted = true;
            _ = wrk.timers.remove(index);
            wrk.statistics.connections +|= 1;
            return out[0..beginAttempt(wrk, entry, now, out, 0)];
        }

        /// The first phase of generation retirement: account the attempt, then ask the engine to
        /// close the transport. The attempt's quota stays spent, so a reconnect only claims what the
        /// run has left instead of handing the failed attempt back.
        pub fn onTransportFailure(wrk: *worker.Worker, index: u32, now: u64, out: []Step) []const Step {
            if (index >= wrk.sessions.len) {
                wrk.markFatal();
                return out[0..0];
            }
            const entry = &wrk.sessions[index];
            if (entry.state == .closing or entry.state == .done) return out[0..0];
            return out[0..fail(wrk, entry, now, out, 0)];
        }

        /// Settles one completed attempt. A verified attempt counts its bytes and its echoes; a
        /// corrupted one counts the same units as corrupted and none as bytes. The latency sample is
        /// the whole attempt, which is one batch.
        pub fn onAttemptSettled(wrk: *worker.Worker, index: u32, now: u64, corrupt: bool, out: []Step) []const Step {
            if (index >= wrk.sessions.len) {
                wrk.markFatal();
                return out[0..0];
            }
            const entry = &wrk.sessions[index];
            if (entry.state == .closing or entry.state == .done) return out[0..0];
            if (corrupt) {
                wrk.statistics.corrupted +|= entry.requested_echoes;
            } else {
                wrk.statistics.echoes +|= entry.requested_echoes;
                wrk.statistics.bytes +|= entry.attempt_bytes;
            }
            entry.settled +|= entry.requested_echoes;
            entry.attempt_accounted = true;
            _ = wrk.timers.remove(index);
            wrk.recordLatency(now -| entry.attempt_started_ticks);
            if (wrk.interval_ticks != 0) {
                entry.state = .pacing;
                entry.send_at_ticks = now +| wrk.interval_ticks;
                wrk.armTimer(index, entry.send_at_ticks);
                return out[0..0];
            }
            return out[0..beginAttempt(wrk, entry, now, out, 0)];
        }

        /// The second phase: the transport proved that every operation of this generation has been
        /// dequeued, so either a reconnect or the terminal state follows.
        ///
        /// The drain itself is not decided here. Whether the provider still owns an operation is a
        /// question about the native slot, and engine.zig answers it before emitting this event; the
        /// business machine is handed the verdict and never inspects native state.
        pub fn onGenerationDrained(wrk: *worker.Worker, index: u32, now: u64, out: []Step) []const Step {
            if (index >= wrk.sessions.len) {
                wrk.markFatal();
                return out[0..0];
            }
            const entry = &wrk.sessions[index];
            _ = wrk.timers.remove(index);
            if (entry.reconnect_after_close and !wrk.stopping) {
                entry.state = .reconnecting;
                entry.reconnect_at_ticks = now +| wrk.reconnect_ticks;
                wrk.armTimer(index, entry.reconnect_at_ticks);
                return out[0..0];
            }
            markDone(wrk, entry);
            return out[0..0];
        }

        /// A controlled stop leaves every unfinished attempt claimed but unsettled: those units are
        /// reported as cancelled by the run, not as losses.
        pub fn beginShutdown(wrk: *worker.Worker) void {
            if (wrk.stopping) return;
            wrk.stopping = true;
            for (wrk.sessions) |*entry| {
                if (entry.state == .done) continue;
                _ = wrk.timers.remove(entry.index);
                entry.reconnect_after_close = false;
                entry.state = .closing;
            }
        }

        pub fn allFinished(wrk: *const worker.Worker) bool {
            for (wrk.sessions) |entry| {
                if (!entry.isFinished()) return false;
            }
            return true;
        }

        pub fn waitTicks(wrk: *const worker.Worker, now: u64, maximum: u64) u64 {
            return wrk.timers.waitTicks(now, maximum);
        }

        /// One attempt is one receive plus one send whatever the pipeline depth is. The quota is
        /// claimed per session, and a batch that would exceed the remaining quota is trimmed rather
        /// than refused, which is what makes the last batch of a run exact.
        fn beginAttempt(wrk: *worker.Worker, entry: *Session, now: u64, out: []Step, base: usize) usize {
            _ = wrk.timers.remove(entry.index);
            const requested = wrk.options.batchCapacity();
            const granted = claimSessionAttempts(&entry.claimed, wrk.options.echo_count, requested);
            if (granted == 0) {
                // The quota is exhausted. The generation is retired rather than left open: the peer
                // must see the connection close as soon as this session has nothing left to echo,
                // and a slot that keeps a live socket would starve the sessions behind it.
                entry.reconnect_after_close = false;
                entry.state = .closing;
                armClose(wrk, entry, now);
                return wrk.emit(out, base, .{ .close = entry.index });
            }
            const attempt_bytes = wrk.payload_bytes * @as(usize, @intCast(granted));
            if (attempt_bytes == 0 or attempt_bytes > std.math.maxInt(u32)) {
                wrk.markFatal();
                return 0;
            }
            entry.requested_echoes = granted;
            entry.attempt_bytes = attempt_bytes;
            entry.send_offset = 0;
            entry.received_bytes = 0;
            entry.send_done = false;
            entry.receive_done = false;
            entry.attempt_accounted = false;
            entry.state = .active;
            entry.active_counted = true;
            entry.send_at_ticks = 0;
            entry.attempt_started_ticks = now;
            wrk.statistics.attempted +|= granted;
            entry.deadline_ticks = now +| wrk.timeout_ticks;
            wrk.armTimer(entry.index, entry.deadline_ticks);
            const length: u32 = @intCast(attempt_bytes);
            var count = wrk.emit(out, base, .{ .receive = .{ .index = entry.index, .bytes = length } });
            count += wrk.emit(out, base + count, .{ .send = .{ .index = entry.index, .bytes = length } });
            return count;
        }

        /// A failed generation settles the attempt's whole quota at once, which is what preserves
        /// the ledger identity attempted = pending + echoed + corrupted + lost + cancelled.
        ///
        /// A reconnect is counted here, at the failure that triggers it, so a stop that arrives while
        /// the session is waiting to reconnect cannot change the tally.
        fn fail(wrk: *worker.Worker, entry: *Session, now: u64, out: []Step, base: usize) usize {
            if (!entry.attempt_accounted) {
                wrk.statistics.lost +|= entry.requested_echoes;
                entry.settled +|= entry.requested_echoes;
                entry.attempt_accounted = true;
            }
            wrk.statistics.network_errors +|= 1;
            const will_reconnect = wrk.reconnect_enabled and !wrk.stopping;
            if (will_reconnect) wrk.statistics.reconnects +|= 1;
            entry.reconnect_after_close = will_reconnect;
            entry.state = .closing;
            armClose(wrk, entry, now);
            return wrk.emit(out, base, .{ .close = entry.index });
        }

        /// Every closing generation keeps a deadline: the drain is normally immediate, but a
        /// provider that never reports the last completion has to end the run rather than hang it.
        fn armClose(wrk: *worker.Worker, entry: *Session, now: u64) void {
            entry.deadline_ticks = now +| wrk.drain_grace_ticks;
            wrk.armTimer(entry.index, entry.deadline_ticks);
        }

        /// A session that cannot make progress any more is terminal: it leaves the active set, its
        /// timer is disarmed, and its socket has already been released by the close step.
        fn markDone(wrk: *worker.Worker, entry: *Session) void {
            _ = wrk.timers.remove(entry.index);
            entry.active_counted = false;
            entry.deadline_ticks = 0;
            entry.send_at_ticks = 0;
            entry.reconnect_at_ticks = 0;
            entry.state = .done;
        }

        /// The quota switch is a per-session quota. A single worker thread owns its sessions, so a
        /// plain counter is enough and the worker keeps the aggregate for the terminal accounting.
        pub fn claimSessionAttempts(claimed: *u64, limit: u64, requested: u64) u64 {
            if (requested == 0) return 0;
            if (limit == 0) {
                claimed.* +|= requested;
                return requested;
            }
            if (claimed.* >= limit) return 0;
            const granted = @min(requested, limit - claimed.*);
            claimed.* +|= granted;
            return granted;
        }
    };
};

pub const worker = struct {
    pub const Phase = enum(u8) { starting, running, draining, stopped };

    /// One completion whose request context decoded successfully. The native ownership accounting
    /// has already been retired by the engine before this record exists.
    pub const Completion = struct {
        index: u32,
        generation: u32,
        slot: u32,
        operation: native.completion.Operation,
        status: i32,
        bytes: u32,
    };

    /// A per-worker progress snapshot.
    ///
    /// The publish interval is tens of milliseconds and the critical section is one structure copy,
    /// so a tiny hand-off is enough. The completion path never touches it, which is what keeps the
    /// statistics worker-local until a report or the terminal merge asks for them.
    pub const Progress = struct {
        lock: std.atomic.Mutex = .unlocked,
        statistics: metrics.Statistics = .{},
        active: u32 = 0,

        pub fn store(self: *Progress, statistics: *const metrics.Statistics, active: u32) void {
            self.acquire();
            self.statistics = statistics.*;
            self.active = active;
            self.lock.unlock();
        }

        pub fn load(self: *Progress, statistics: *metrics.Statistics, active: *u32) void {
            self.acquire();
            statistics.* = self.statistics;
            active.* = self.active;
            self.lock.unlock();
        }

        fn acquire(self: *Progress) void {
            var spins: u32 = 0;
            while (!self.lock.tryLock()) {
                spins +%= 1;
                if (spins % 64 == 0) std.Thread.yield() catch {};
            }
        }
    };

    /// Trace events are compiled out of a release build, and in a debug build they stay a single
    /// predictable branch on a global flag, so the completion path never formats a string unless
    /// tracing was explicitly requested.
    pub const trace = struct {
        const compiled_in = builtin.mode == .debug;
        var enabled: bool = false;

        pub fn configure() void {
            if (!compiled_in) return;
            const value = native.environment("CEC_TRACE");
            enabled = value != null and value.?[0] != 0;
        }

        pub inline fn event(comptime name: []const u8) void {
            if (!compiled_in or !enabled) return;
            emit(name, "");
        }

        pub fn eventArgs(comptime name: []const u8, comptime format: []const u8, args: anytype) void {
            if (!compiled_in or !enabled) return;
            var buffer: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&buffer, format, args) catch return;
            emit(name, body);
        }

        fn emit(name: []const u8, body: []const u8) void {
            var buffer: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "client-trace {s} {s}\n", .{ name, body }) catch return;
            _ = native.diagnostics.writeStderr(line);
        }
    };

    /// One worker: the business ledger, the timer heap and the native objects it owns outright.
    ///
    /// Keeping the native owners in this record is what lets every other module treat a worker as
    /// plain data with no runtime dispatch; only engine.zig dereferences the native fields.
    pub const Worker = struct {
        index: u32 = 0,
        session_count: u32 = 0,
        options: *const types.Options = undefined,
        clock: native.clock.Clock = .{},
        payload_bytes: usize = 0,
        timeout_ticks: u64 = 0,
        interval_ticks: u64 = 0,
        reconnect_ticks: u64 = 0,
        reconnect_enabled: bool = false,
        /// The bounded grace a closing generation gets before its silence is fatal.
        drain_grace_ticks: u64 = 0,
        receive_flags: u32 = 0,

        statistics: metrics.Statistics = .{},
        bench_histogram: metrics.WorkerHistogram = if (metrics.benchmark_enabled) metrics.Histogram{} else {},

        sessions: []session.Session = &.{},
        /// The native state of each session's current generation. The business machine above never
        /// reaches into it; engine.zig owns every field.
        slots: []native.transport.Slot = &.{},
        /// The step scratch buffer, split into fixed regions. A scheduler decision runs in one
        /// region, so a step produced while another is being executed can never overwrite the step
        /// being executed.
        steps: []session.scheduler.Step = &.{},
        step_depth: u32 = 0,
        timer_nodes: []timer.Node = &.{},
        timer_positions: []u32 = &.{},
        timers: timer.Heap = .{},

        progress: ?*Progress = null,
        progress_interval_ticks: u64 = 0,
        next_progress_ticks: u64 = 0,

        phase: Phase = .starting,
        stopping: bool = false,
        notification_arms: u64 = 0,
        notification_deliveries: u64 = 0,
        timeout_wakeups_while_outstanding: u64 = 0,

        // Native ownership.
        port: native.handle.Handle = .{},
        thread: native.handle.Handle = .{},
        completion_queue: native.rio.CompletionQueue = .{},
        arena: native.arena.Arena = .{},
        api: ?*const native.rio.Api = null,
        connect_ex: ?c.LPFN_CONNECTEX = null,
        remote_address: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN),
        notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),

        pub fn markFatal(self: *Worker) void {
            self.statistics.fatal = true;
        }

        pub fn armTimer(self: *Worker, index: u32, deadline: u64) void {
            if (!self.timers.insertOrUpdate(index, deadline)) self.markFatal();
        }

        pub fn disarmTimer(self: *Worker, index: u32) void {
            _ = self.timers.remove(index);
        }

        /// Three steps per session at most: a connect, a receive and a send. Emitting past the fixed
        /// scratch buffer is an internal invariant failure, not a capacity a caller may exceed.
        pub fn emit(self: *Worker, out: []session.scheduler.Step, position: usize, step: session.scheduler.Step) usize {
            if (position >= out.len) {
                self.markFatal();
                return 0;
            }
            trace.eventArgs("STEP", "step={s}", .{@tagName(step)});
            out[position] = step;
            return 1;
        }

        /// Takes the next step region. Running out of levels means the decision recursion is deeper
        /// than the design allows, which is an internal invariant failure rather than a capacity a
        /// caller may exceed.
        pub fn acquireRegion(self: *Worker) []session.scheduler.Step {
            const stride = stepRegionBytes(self.session_count);
            if (stride == 0 or self.step_depth >= step_levels) {
                self.markFatal();
                return &.{};
            }
            const start = stride * self.step_depth;
            if (start + stride > self.steps.len) {
                self.markFatal();
                return &.{};
            }
            self.step_depth += 1;
            return self.steps[start .. start + stride];
        }

        pub fn releaseRegion(self: *Worker) void {
            if (self.step_depth == 0) {
                self.markFatal();
                return;
            }
            self.step_depth -= 1;
        }

        pub fn liveSessions(self: *const Worker) u32 {
            var count: u32 = 0;
            for (self.sessions) |entry| {
                if (!entry.isFinished()) count += 1;
            }
            return count;
        }

        pub fn activeSessions(self: *const Worker) u32 {
            var count: u32 = 0;
            for (self.sessions) |entry| {
                if (entry.active_counted) count += 1;
            }
            return count;
        }

        /// Publishes the ledger into the shared snapshot. A forced publish is the terminal one.
        pub fn publish(self: *Worker, now: u64, force: bool) void {
            const snapshot = self.progress orelse return;
            if (!force and now < self.next_progress_ticks) return;
            const active = self.activeSessions();
            snapshot.store(&self.statistics, active);
            self.next_progress_ticks = now +| self.progress_interval_ticks;
        }

        pub fn recordLatency(self: *Worker, ticks: u64) void {
            const micros: u64 = if (self.clock.frequency == 0)
                1
            else
                @intCast(@max(@as(u128, 1), @as(u128, ticks) * 1_000_000 / @as(u128, self.clock.frequency)));
            self.statistics.recordLatency(micros);
            if (metrics.benchmark_enabled) self.bench_histogram.record(micros);
        }

        pub fn elapsedMilliseconds(self: *const Worker, now: u64, started: u64) u64 {
            if (now <= started) return 0;
            return self.clock.ticksToMilliseconds(now - started);
        }

        /// The release order the design fixes: retire outstanding operations, close the completion
        /// queue and its notification state, deregister every buffer, release the single virtual
        /// allocation, free the host-side arrays, and only then close the completion port.
        pub fn release(self: *Worker, allocator: std.mem.Allocator) void {
            for (self.slots) |*slot| slot.close();
            self.completion_queue.deinit();
            self.arena.deinit();
            if (self.sessions.len != 0) allocator.free(self.sessions);
            if (self.slots.len != 0) allocator.free(self.slots);
            if (self.steps.len != 0) allocator.free(self.steps);
            if (self.timer_nodes.len != 0) allocator.free(self.timer_nodes);
            if (self.timer_positions.len != 0) allocator.free(self.timer_positions);
            self.sessions = &.{};
            self.slots = &.{};
            self.steps = &.{};
            self.timer_nodes = &.{};
            self.timer_positions = &.{};
            self.timers = .{};
            self.port.deinit();
            self.thread.deinit();
            self.phase = .stopped;
        }
    };
};

test "timer heap insert update remove" {
    var nodes: [8]timer.Node = undefined;
    var positions: [8]u32 = undefined;
    var heap = try timer.Heap.init(&nodes, &positions);
    try std.testing.expect(heap.insertOrUpdate(3, 30));
    try std.testing.expect(heap.insertOrUpdate(1, 10));
    try std.testing.expect(heap.insertOrUpdate(5, 20));
    try std.testing.expectEqual(@as(?u32, 1), heap.popExpired(10));
    try std.testing.expect(heap.insertOrUpdate(5, 5));
    try std.testing.expectEqual(@as(?u32, 5), heap.popExpired(5));
    try std.testing.expect(heap.remove(3));
    try std.testing.expectEqual(@as(u32, 0), heap.len);
    try std.testing.expectEqual(@as(u64, 100), heap.waitTicks(0, 100));
    try std.testing.expect(heap.insertOrUpdate(2, 50));
    try std.testing.expectEqual(@as(u64, 50), heap.waitTicks(0, 100));
    try std.testing.expectEqual(@as(u64, 10), heap.waitTicks(40, 100));
    try std.testing.expectEqual(@as(u64, 0), heap.waitTicks(60, 100));
}

test "the per-session quota is trimmed, never refunded" {
    var claimed: u64 = 0;
    try std.testing.expectEqual(@as(u64, 4), session.scheduler.claimSessionAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 1), session.scheduler.claimSessionAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 0), session.scheduler.claimSessionAttempts(&claimed, 5, 4));
    try std.testing.expectEqual(@as(u64, 5), claimed);
    var unlimited: u64 = 0;
    try std.testing.expectEqual(@as(u64, 7), session.scheduler.claimSessionAttempts(&unlimited, 0, 7));
    try std.testing.expectEqual(@as(u64, 7), unlimited);
    try std.testing.expectEqual(@as(u64, 7), session.scheduler.claimSessionAttempts(&unlimited, 0, 7));
    try std.testing.expectEqual(@as(u64, 14), unlimited);
}
