# Zig echo client performance refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the independent Zig client easier to reason about and faster on measured Windows loopback workloads without changing its CLI, TCP/UDP semantics, or RIO + IOCP architecture.

**Architecture:** Keep `engine_internal.zig` as the stable state/ownership vocabulary; move session transitions to `client_session.zig`, worker event-loop and resources to `client_worker.zig`, and leave `engine.zig` as coordinator/reporting. Benchmark-only instrumentation is compile-time gated. Optimize one profiled hot path at a time; a structural cleanup is not a performance claim.

**Tech Stack:** Zig `0.17.0-dev.2375+d8aab4878`, Windows x64 MSVC ABI and Microsoft SDK, Winsock RIO, IOCP/ConnectEx, PowerShell 7 benchmark/test scripts.

**Spec:** `docs/superpowers/specs/2026-10-01-zig-performance-refactor-design.md`

## Global Constraints

- This repository builds and tests alone. External Zig/C++ server executables are explicit test inputs only; do not import or link sibling projects.
- All payload transfers and data completions use RIO; IOCP handles CQ notification, ConnectEx completion, and control. A CQ notification is not an operation completion. No alternate payload path or polling fallback.
- Exactly one worker owns each RQ/CQ, session, timer heap, and registered arena. `RIO_BUF`, `OVERLAPPED`, and request-context addresses stay stable after publication.
- Synchronous, pre-publication setup may use Zig error unions and `errdefer`; posted ConnectEx/RIO work retires only after terminal completion and CQ drain. Preserve existing fail-fast checks for impossible runtime invariants.
- Preserve CLI/defaults/exit-code categories/output fields, finite `/n` without implicit `/w`, `claimAttempts`/`unclaimedEchoes`, TCP partial-send and UDP datagram rules, pacing/reconnect/stop semantics. Normal production statistics remain unchanged.
- No toolchain installation, build, or runtime verification is claimed by this document. Execution preflight requires the exact pinned Zig version; if unavailable, pause for user direction rather than silently downloading it. Use Zig structs/slices for private owners, `extern` only for native ABI, and `comptime` only for genuinely compile-time-known choices.
- Every source-changing commit: `./build.ps1 -Optimize Debug` and `./build.ps1 -Optimize ReleaseFast`; keep benchmark artifacts under ignored `zig-out/bench/`. No merge/push until review.

## Review Focus

1. `/n` not divisible by TCP `/k`: the final partial batch claims exactly the remainder; Task 4 adds a 17-echo `/k 8` regression.
2. Two workers racing for the final finite quota: global `claimed` never exceeds `/n`; Task 5 adds the exact-quota multiworker test.
3. Stop or connection failure with posted receive/send/ConnectEx: no buffer/context release until terminal completions; Tasks 3-5 exercise it.
4. Periodic report concurrent with worker metric updates: atomic reads never tear and final totals agree after join; Task 6 adds the publication test.
5. A benchmark run with loss, corruption, network error, short duration, or wrong peer: it is rejected, not counted as a speedup; Task 1 tests the runner's rejection path.

---

## File map and dependency order

| File | Responsibility |
| --- | --- |
| `tests/perf_commands.ps1`, `tests/perf_loopback.ps1`, `tests/perf_runner_contract.ps1`, `tests/perf_workloads.json` | Independent, finite-count workload construction, execution, provenance, and invalid-run rejection. |
| `src/bench_histogram.zig`, `build.zig`, `tests/bench_histogram.zig` | Opt-in bounded, worker-local finer batch-latency measurement; default binary/output unchanged. |
| `src/engine_internal.zig` | Stable session/worker/request types and typed `WorkerResources`; later worker-local statistics. |
| `src/client_session.zig` | Single-session socket, ConnectEx, RIO, timer, accounting, reconnect, and close transitions. |
| `src/client_worker.zig` | One-worker CQ/IOCP loop, initialization, publication, stop, join, drain, and retirement. |
| `src/engine.zig`, `src/root.zig` | Coordinator, command-level result, reporting and compatibility exports needed by existing tests. |
| `tests/engine.zig`, `tests/process_tests.ps1`, `tests/fault_process_tests.ps1` | Unit, process, fault, and shutdown barriers. |
| `docs/perf-results-2026-10-01.md` | Baseline, profiler evidence, candidate decisions, A/B/A statistics, correctness matrix. |

The list is an ownership map, not an instruction to alter every file. `sdk.zig`, `rio.zig`, and the public CLI parser stay unchanged unless a focused test demonstrates a defect. Read the spec and this plan before Task 1. Execute sequentially on an isolated implementation branch/worktree from the reviewed design branch.

### Task 1: Reproducible finite-count runner and baseline gate

**Files:** Create `tests/perf_commands.ps1`, `tests/perf_loopback.ps1`, `tests/perf_runner_contract.ps1`, `tests/perf_workloads.json`; later create `docs/perf-results-2026-10-01.md`.

**Interfaces:** `New-ClientArguments -Case <PSCustomObject> -Port <int>` returns `[string[]]`; `Test-BenchmarkRun -Run <PSCustomObject> -ExpectedPeerSha256 <string>` returns `[bool]`; `./tests/perf_loopback.ps1 -ClientPath <path> -PeerPath <path> -PeerPid <int> -PeerArguments <string[]> -ExpectedPeerSha256 <string> -Port <int> -Case <name> -OutputDirectory <path> -Label <string> [-DescribeOnly]` reads the project-local manifest. It assumes the peer is already running and never starts/builds/kills it. Each manifest row has `name`, `protocol`, `payload_bytes`, `pipeline_depth`, `sessions`, `threads`, `cq`, `memory_bytes`, `socket_buffer_bytes`, `echo_count` (positive integer).

- [ ] Write `tests/perf_runner_contract.ps1`: assert TCP 17-echo `/k 8` and UDP 65507 argument vectors include `/n` and omit `/w`; reject zero/negative counts, mismatched peer hash, nonzero exit, `lost`/`corrupted`/`network_errors` nonzero, and measured duration under 10 s. `-DescribeOnly` skips live-process validation and emits arguments without running a binary.
- [ ] Run `pwsh -NoProfile -File tests/perf_runner_contract.ps1`; expect failure because the runner/functions do not exist.
- [ ] Implement manifest cases: TCP 128 `/k 1`, TCP 4096 `/k 8`, UDP 1200 and 65507, plus TCP 256/1024/4096-session sweep when capacity permits. Start pilot at `/n 100000`, double until a valid run lasts at least 10 s, then freeze those exact counts in the manifest. The runner records commands, stdout/stderr, exit, executable SHA-256, Git commit, Zig/Windows/CPU, elapsed and process CPU time to a unique `zig-out/bench/<label>/` run directory; invalid runs exit nonzero. `-DescribeOnly` does no execution.
- [ ] Run `pwsh -NoProfile -File tests/perf_runner_contract.ps1`; expect PASS. Run both `./build.ps1 -Optimize Debug` and `./build.ps1 -Optimize ReleaseFast`; expect complete self-contained suites PASS with pinned 2375.
- [ ] With an explicitly supplied live peer, run one warmup and seven valid runs per frozen case; archive immutable baseline executable/hash and raw output, and record profiler counters (CPU, cache misses/contention if available) before choosing a code candidate. Record a separately built C++ client as an informative reference, not the Zig acceptance baseline. No competing benchmark pair may run concurrently. Review decisions use `delta > max(0.05 * baseline_median, 3 * baseline_MAD)` in the measured metric's units.
- [ ] Commit the runner, frozen manifest, and baseline report (`git add tests/perf_commands.ps1 tests/perf_loopback.ps1 tests/perf_runner_contract.ps1 tests/perf_workloads.json docs/perf-results-2026-10-01.md`; `git commit -m "test: establish Zig client performance baseline"`). Raw `zig-out/bench/` data remains local during runs; attach a hashed raw-sample archive to implementation review so results are inspectable.

### Task 2: Opt-in precise latency evidence

**Files:** Create `src/bench_histogram.zig`, `tests/bench_histogram.zig`; modify `build.zig`, `src/engine.zig`, `src/engine_internal.zig`, `src/root.zig`.

**Interfaces:** `bench_histogram.Histogram.init() Histogram`, `record(self: *Histogram, micros: u64) void`, `percentile(self: *const Histogram, numerator: u64, denominator: u64) u64`. Build option `-Dbench-histogram=true` defaults false; `build.zig` imports the generated `bench_config.enabled: bool` into application and test root modules. Histogram is fixed 4096 buckets: 64 sub-buckets in each of 64 power-of-two bands, saturating the last band; map band by `floor(log2(max(1, micros)))`, then a 0-63 linear sub-bucket using widened integer arithmetic. One owner worker writes its own histogram. Benchmark build emits a separate `bench_latency_sample=batch ...` line; existing `report`/`final` lines and production build remain byte-for-byte unchanged.

- [ ] Write tests for 1 µs, bucket boundaries, saturation, 50/99/999 percentile rank, and the disabled-build absence of benchmark fields; include a test that the new histogram count equals completed batch count, not echoed logical messages. Wire `tests/bench_histogram.zig` into `build.zig` before implementing its imported module, so the red run actually compiles the failing test.
- [ ] Run `./build.ps1 -Optimize Debug`; expect failure because the module/build option is absent.
- [ ] Add the bounded histogram and compile-time switch using the pinned Zig build API. Record latency only after a completed batch; no allocation or shared atomic increment in this benchmark-only hot path. Build an instrumented baseline binary from this commit and use that same instrumentation revision for every later candidate comparison.
- [ ] Run `./build.ps1 -Optimize Debug`, `./build.ps1 -Optimize ReleaseFast`, and the Task 1 runner's `-DescribeOnly` contract; expect PASS. Check default `final` field names and values with `tests/process_tests.ps1`.
- [ ] Commit (`git add src/bench_histogram.zig tests/bench_histogram.zig build.zig src/engine.zig src/engine_internal.zig src/root.zig`; `git commit -m "test: add opt-in client tail latency histogram"`).

### Task 3: Typed ownership before asynchronous publication

**Files:** Modify `src/engine_internal.zig`, `src/engine.zig`, `tests/engine.zig`, `tests/fault_driver.zig`.

**Interfaces:** Move `WorkerResources` to `engine_internal.zig`; change `Worker.resources` from `?*anyopaque` to `?*WorkerResources`; retain `engine.WorkerResources` as an alias for existing tests. Keep `initializeWorker(..., owner: *WorkerResources) bool` for this task; do not change runtime failure categories yet. `destroyWorker(*Worker)` must enforce terminal outstanding=0 after a started thread.

- [ ] Add a compile-time assertion that `Worker.resources` has type `?*internal.WorkerResources`; test that a partly initialized, unpublished owner releases only acquired resources, a published owner cannot release with one outstanding RIO/ConnectEx operation, and a foreign request context is rejected.
- [ ] Run `./build.ps1 -Optimize Debug`; expect the new typed-owner assertions/tests to fail before the change.
- [ ] Replace `@ptrCast(@alignCast(worker.resources.?))` with a typed pointer, keep stable preallocated slices, and make synchronous cleanup explicit in the existing owner methods. Do not `errdefer` any resource after thread/request publication.
- [ ] Run full Debug and ReleaseFast suites plus existing fault/shutdown process tests; expect PASS and no changed CLI output.
- [ ] Commit (`git add src/engine_internal.zig src/engine.zig tests/engine.zig tests/fault_driver.zig`; `git commit -m "refactor: type client worker resource ownership"`).

### Task 4: Extract Zig session state machine without changing behavior

**Files:** Create `src/client_session.zig`; modify `src/engine.zig`, `src/root.zig`, `tests/engine.zig`, `tests/process_tests.ps1`, `tests/fault_process_tests.ps1`.

**Interfaces:** `client_session.beginAttempt(*internal.Session) bool`, `processConnect(*internal.Session, bool, u32) void`, `processRioResult(*internal.Worker, c.RIORESULT) void`, `processDeadlines(*internal.Worker) void`, `closeAttempt(*internal.Session, bool) void`. Keep public `engine.*` names used by current tests as aliases/forwarders. The session module imports `engine_internal`, not `client_worker`, to avoid an import cycle.

- [ ] Add a test import of `client_session.zig` (red before file exists), plus `/n 17, /k 8` gives 8+8+1 with exact echoed/bytes; partial `RIOSend` advances offset without reusing a live buffer; closing after a posted send+receive leaves the session alive until both completions; ConnectEx failure counts a claimed active attempt once.
- [ ] Run `./build.ps1 -Optimize Debug`; expect the new tests to fail before extraction/fix.
- [ ] Move the existing session/socket/timer/accounting functions with unchanged state transitions and native API calls; leave only compatibility exports in `engine.zig`. Do not introduce `std.Io`, movable containers, or per-attempt allocation. Keep `claimAttempts` global atomic and `unclaimedEchoes` final accounting exactly as before.
- [ ] Run full Debug/ReleaseFast suites and `pwsh -NoProfile -File tests/interoperability.ps1 -ServerPath <external-server.exe>` for TCP normal/partial tail and UDP 1200/65507; expect zero corruption/loss/network errors. Use explicit external path, never a build dependency.
- [ ] Commit (`git add src/client_session.zig src/engine.zig src/root.zig tests/engine.zig tests/process_tests.ps1 tests/fault_process_tests.ps1`; `git commit -m "refactor: isolate client session transitions"`).

### Task 5: Extract worker loop and stage setup errors

**Files:** Create `src/client_worker.zig`; modify `src/engine.zig`, `src/engine_internal.zig`, `src/root.zig`, `tests/engine.zig`, `tests/fault_driver.zig`.

**Interfaces:** `client_worker.initializeWorker(worker: *internal.Worker, extensions: *const rio.Extensions, options: *const types.Options, remote: *const c.SOCKADDR_IN, pattern: []const u8, maximum_attempt_bytes: usize, metrics: *internal.Metrics, external_stop: *std.atomic.Value(bool), fatal: *std.atomic.Value(bool), worker_index: u32, session_count: u32, memory_share: u64, owner: *internal.WorkerResources) InitError!void`; `startWorker(*internal.Worker) bool`, `postWorkerStop(*internal.Worker) void`, `joinWorker(*internal.Worker) void`, `destroyWorker(*internal.Worker) void`, `retireCompletionQueue(*internal.Worker) void`. `InitError = error{Frequency, Port, Capacity, Arena, Sessions, TimerNodes, TimerPositions, SocketOwners, TimerHeap, Registration, CompletionQueue}`. Preserve native diagnostics and `.network` mapping in `engine.runClient`; keep existing `engine.*` test entry points as forwarders.

- [ ] Import the not-yet-created `client_worker.zig` in the worker tests (red), then test two workers claiming exactly `/n 17` with `/k 8`; RIO notification is delivered then CQ drained then rearmed once; stop with an armed/queued notification converges; initialization failure at each acquired-resource stage leaves no published request/owned leak.
- [ ] Run `./build.ps1 -Optimize Debug`; expect compile/test failure before the worker module and `InitError` are introduced.
- [ ] Move CQ/IOCP loop and worker init/start/stop/join/retirement. Use `errdefer` only inside `initializeWorker` before ready/thread/request publication; on error reset owner and `worker.resources`, and change `runClient` so it does not destroy an already rolled-back failed initializer. Once published, the worker-thread state machine owns shutdown and terminal drain. Do not alter `batch_size=256` in this structural task.
- [ ] Run full Debug/ReleaseFast suites, fault tests, external-stop test, and client interoperability. Confirm `lost=0` for successful finite `/n`, no unaccounted quota after early failure, and CQ retirement only at zero outstanding.
- [ ] Commit (`git add src/client_worker.zig src/engine.zig src/engine_internal.zig src/root.zig tests/engine.zig tests/fault_driver.zig`; `git commit -m "refactor: isolate client worker lifecycle"`).

### Task 6: Profile-gated worker-local metrics experiment

**Files:** Modify `src/engine_internal.zig`, `src/client_session.zig`, `src/client_worker.zig`, `src/engine.zig`, `tests/engine.zig`, `docs/perf-results-2026-10-01.md`.

**Interfaces:** `internal.Metrics.claimed: std.atomic.Value(u64)` remains global. Add `internal.WorkerMetrics` with worker-owned atomic echoed/corrupted/lost/bytes/network_errors and `[64]` coarse latency bins; `internal.Worker.local_metrics: ?*WorkerMetrics`; `engine.aggregateMetrics(workers: []const internal.Worker, claimed: u64) MetricsSnapshot`, where `MetricsSnapshot` contains plain `u64` totals and `[64]u64` bins. Change `engine.printMetrics(phase: []const u8, options: *const types.Options, snapshot: *const MetricsSnapshot, elapsed_ms: u64) void`; periodic aggregation uses atomic loads and may be non-simultaneous across workers, while final aggregation runs after all joins.

- [ ] Record a baseline profile. If shared metrics cache-line contention is not visible, record `SKIPPED: no contention evidence` and do not change source; Task 7 may still assess another hotspot. If visible, add tests for two-worker concurrent increments beyond 32 bits, periodic reads without data races, exact final totals after join, and `/n` claim unaffected.
- [ ] For an evidence-backed candidate, run the focused Debug test before implementation; expect failure because `WorkerMetrics`/`aggregateMetrics` do not exist.
- [ ] Implement worker-local atomic counters and a read-only aggregation snapshot. No racy reads of non-atomic mutable worker fields and no seqlock over ordinary fields. Preserve the current report field names, units, batch sample meaning, and `claimAttempts` ordering; after all joins, add `unclaimedEchoes` to lost exactly once before the final snapshot/classification.
- [ ] Run full Debug/ReleaseFast suites, 4-way Zig/C++ TCP+UDP interoperability (including partial TCP tail and UDP 65507), then A/B/A runner with identical peer/instrumentation. Retain only if correctness holds and median gain exceeds both 5% and 3 baseline MAD without another required workload's throughput or p99/p999 regressing beyond that threshold; otherwise revert only this candidate on its isolated branch and record the rejection.
- [ ] Commit the accepted source/report, or report-only skip/rejection (`git commit -m "perf: evaluate worker-local client metrics"`).

### Task 7: One further measured Zig-native hot-path candidate and final acceptance

**Files:** Modify only the selected hot-path file(s) among `src/client_session.zig`, `src/client_worker.zig`, `src/engine_internal.zig`, `src/timer_heap.zig`; modify the corresponding `tests/engine.zig` or `src/timer_heap.zig` tests and `docs/perf-results-2026-10-01.md`.

**Interfaces:** Choose exactly one profiled candidate: stable session hot/cold field layout, CQ dequeue batch constant (compare 128/256/512), timer-heap access, or compile-time-specialized payload validation. Preserve public interfaces and native context addresses. Record choice and profiler evidence before editing; if none is evidenced, mark this task skipped without speculative source changes.

- [ ] Add one failing focused test for the selected parameter/layout/specialization itself and its invariant (context pointer identity after layout change; exact drain/rearm after CQ batch change; deadline ordering after timer change; byte-exact mismatch detection after validation change).
- [ ] Run focused Debug test; expect failure before implementation.
- [ ] Change only the selected variable, with a compile-time-known specialization only where it removes measured work; do not build generic abstractions or alter affinity/NUMA simultaneously.
- [ ] Run both full suites, fault/stop/storm-like client cases, and the four Zig/C++ interop combinations. Compare at least seven valid A/B/A samples per frozen workload. Reject a candidate with loss, corruption, incomplete drain, or material p99/p999 regression regardless of throughput.
- [ ] Commit only accepted source plus report, or report-only skip/rejection. Final report must distinguish structural cleanup, measured speedup, inconclusive result, and rejected experiment; state exact commits, compiler and machine, raw artifact hashes, median/MAD, p50/p99/p999, and shutdown convergence.

## Completion boundary

The implementation is complete only after the reviewed plan's applicable tasks pass, both configurations build and test with pinned 2375, external interoperability is current, baseline/candidate artifacts are comparable, and each retained speedup has the stated evidence. Stop for user review before merge or push. Do not describe this written plan as an implemented or benchmark-verified optimization.
