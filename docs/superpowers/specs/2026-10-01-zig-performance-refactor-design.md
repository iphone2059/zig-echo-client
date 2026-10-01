# Zig echo client: performance-first refactor design

Date: 2026-10-01

Status: written design for user review; not an implementation plan

## Intent and boundary

Improve TCP/UDP throughput and tail latency on reproducible Windows loopback workloads while making the implementation more natural to Zig. Internal layout may change substantially. The externally visible client contract and the native concurrency model do not change. This repository remains independently buildable; an external server executable is only an optional benchmark/interoperability peer, never a source, link, or build dependency.

The starting implementation is commit `8f9dde3`. The current client has a fixed set of workers, one RIO CQ and IOCP notification port per worker, stable preallocated sessions, registered payload memory, ConnectEx for TCP connection setup, and RIO for all payload transfers. The large `src/engine.zig` contains both coordinator and worker/session logic; `src/engine_internal.zig` defines states, contexts, and shared atomic metrics. These are the primary refactor boundaries, not evidence that either layout is slow.

## Preserved contract

- Keep the existing CLI flags, defaults, validation, exit-code categories, output field names/units, finite `/n` behavior without an implicit `/w`, TCP batching and partial-send handling, UDP datagram limits, reconnect, pacing, timeout, and stop semantics.
- Use only RIO for payload receive/send and RIO CQ completion. IOCP remains the mechanism for RIO CQ notification, ConnectEx completion, and worker control. A notification means that the CQ may be dequeued; it is not a data completion. Do not add ordinary Winsock payload I/O, a polling fallback, or another scheduler.
- Preserve fixed ownership of each RQ/CQ by one worker thread. Do not publish movable request/session storage or access a queue concurrently from multiple workers.
- Keep registered buffers, request contexts, sockets, and CQ alive until every posted operation reaches a terminal completion. Closing/cancelling a socket is not itself proof that dependent memory can be freed. Drain the CQ and verify zero outstanding operations before retirement.
- Keep finite-`/n` accounting exact under the existing `claimAttempts` and `unclaimedEchoes` rules: never over-claim, and preserve how an uncontrolled early termination counts unclaimed quota as `lost`. `bytes` counts successfully echoed payload bytes; latency samples represent completed batches rather than logical echoes. Periodic reports may observe concurrent progress but must not contain torn or undefined reads.
- Keep the MSVC ABI target and project-private Windows/RIO declarations checked against the installed Microsoft SDK. No shared source/build path with the server or C++ projects.

## Measurement contract

Before changing hot-path code, record a baseline from the current commit with the pinned Zig `0.17.0-dev.2320+1e770dbef` toolchain and ReleaseFast build. Add a project-local loopback benchmark runner that accepts an explicit, already-running server address/port; it does not build or import another project. The runner uses finite `/n` and omits client `/w`. It writes raw stdout/stderr, exit status, exact command, executable hash/commit, Zig/Windows/CPU details, workload parameters, wall time, and process CPU time beneath ignored `zig-out/bench/`.

Freeze the workload manifest after a pilot selects a finite `/n` large enough for at least 10 seconds of steady operation on this machine. Include at least TCP 128-byte `/k 1`, TCP 4096-byte `/k 8`, UDP 1200-byte, and UDP 65507-byte cases, plus a TCP concurrency sweep at 256, 1024, and 4096 sessions when capacity permits. Record `/threads`, `/cq`, `/memory`, socket buffers, peer executable, and server settings. Failed or lossy pilot cases are corrected and re-frozen before comparison; they are never counted as throughput wins. Only one benchmark pair runs at a time. Warm up, then collect at least seven measured runs per workload, interleaving baseline/candidate/baseline where practical to expose machine drift. Record a separately built C++ client under the same workload as an informative reference, not as the acceptance baseline for a Zig-only source change.

The current power-of-two latency histogram is useful for regression screening but too coarse for a fine p99/p999 improvement claim. Add an optional benchmark-only, fixed-capacity, worker-local finer histogram, with identical instrumentation compiled into baseline and candidate binaries. Keep the normal CLI statistics format unchanged and benchmark instrumentation out of the default production path. Throughput is compared with the same instrumentation mode on both sides. Report run-level median and median absolute deviation, not only the best run. A change is a measured improvement only if its median gain exceeds both 5% and three baseline median absolute deviations; it must not regress another required workload's median throughput or p99/p999 beyond the same noise-aware threshold. If the measurement distribution is too noisy to decide, report inconclusive and rerun under a more controlled environment.

## Refactor and optimization sequence

1. Establish the measurement runner and immutable baseline artifacts, then rerun the complete existing Debug and ReleaseFast test suites. Keep a before/after binary pair so a later compiler or Windows update does not masquerade as a source optimization.
2. Separate coordinator/reporting from fixed-worker/session transitions. Keep native ABI types in `sdk.zig`; make ownership and `init`/`deinit` responsibilities explicit in project-local Zig types. Use Zig error unions and `errdefer` only for synchronous, pre-publication initialization. Once an operation is posted, teardown is a state-machine action after completion drain, not lexical cleanup. Refactor in small behavior-preserving steps and verify each one.
3. Profile the baseline before selecting a hot-path candidate. First candidate: move per-batch echo/byte/latency counters from one shared metrics object to worker-owned counters with race-free, explicitly published periodic snapshots; keep the global finite-`/n` claim counter atomic. Final aggregation occurs after worker join. If profiling does not show contention or cache-line traffic here, do not perform this change.
4. Consider session hot/cold field layout, CQ batch size, timer access, or payload validation code generation only when profiling points to them. Stable addresses for `RIO_BUF`, `OVERLAPPED`, and request contexts are mandatory. Change one variable per benchmark comparison; retain only measured wins that pass correctness gates.

## Verification and completion gates

- Every intermediate commit builds and passes the project's self-contained tests, including parser/payload contracts, SDK ABI, source policy, loopback process, fault, shutdown, and ownership checks. Extend focused tests before altering a state transition.
- After each material change, run TCP and UDP interoperability in all four combinations of Zig/C++ client and Zig/C++ server, with both normal batches and TCP partial tail, and with UDP 1200- and 65507-byte datagrams. The external executable paths are explicit test inputs.
- Stress finite-`/n`, reconnect, externally requested stop, outstanding-operation drain, CQ re-arm, failed connection/setup, and repeated start/stop. No corruption, unaccounted loss, use-after-free, or leaked outstanding RIO work is acceptable.
- Publish raw benchmark samples and comparison method. A throughput win with a meaningful p99/p999 regression is rejected. A structural cleanup may be kept if behavior is unchanged and performance is within measured noise, but it is not reported as a performance optimization.
- Do not merge or push implementation work based on a passing build alone. Review the design and subsequent implementation plan first; keep code changes on an isolated branch/worktree until accepted.

## Exclusions

No cross-project shared library, replacement of RIO/IOCP with `std.Io` or another runtime, ordinary socket fallback, protocol redesign, public CLI redesign, promise of hardware-independent peak throughput, or simultaneous modification of multiple hot-path mechanisms without separate measurements.
