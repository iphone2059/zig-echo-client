# Zig client performance evidence (2026-10-01)

Status: pre-refactor ReleaseFast baseline. This is not an optimization result.

## Provenance and validity

- Zig: `0.17.0-dev.2375+d8aab4878`, target `x86_64-windows-msvc`; Microsoft SDK ABI, source-policy, process/fault, and Debug/ReleaseFast self-contained suites passed before sampling.
- Client commit at build: `12d29995271a0d5773100fc57aa7755168d03313`; executable SHA-256 `192f103a531c1bb39b0a21a27bb00d0ef374182bec7de16aa23b61bc8f337e94`. Immutable copy: `zig-out/bench/baseline/bin/zig-echo-client.exe`.
- External Zig server commit: `f8be8e0ced1f76086242cdca032469db17c6ee01`; executable SHA-256 `103bc0c5df9ddd5981ed40cfa91d8a6ba5e53c0bd158aaf5c7c75428f22f5439`. It was separately built; it is not a source/build dependency of this client.
- Host: Windows `10.0.26300.0`, Intel Core i7-12700H. Each run records exact client/server arguments, peer PID, binary hashes, raw stdout/stderr, process CPU time, wall time, and compiler version in `zig-out/bench/`.
- Six workloads were piloted from `/n 100000` by doubling. The TCP 128B `/k 1` count was doubled once more from its first 10-second pilot to avoid a near-threshold run. Frozen counts are in `tests/perf_workloads.json`. The client had finite `/n` and no `/w`; the external benchmark server used `/w` only as a safety timeout and was stopped after its client series. These samples do not establish graceful server shutdown.
- One warmup and seven measured runs per workload, serially, all with exit 0, exact echoed count/bytes, `lost=0`, `corrupted=0`, `network_errors=0`, and wall time at least 10 seconds. No run was removed as an outlier.
- Raw samples plus four single-run C++ references: `zig-out/bench/baseline/raw-samples.zip`, SHA-256 `6e394927755bba10da8d0c0d4d97a57a5caa469c523ff6fe6b069ce7423fbdcc`. This ignored archive must be attached to implementation review; a hash alone is not a substitute for the raw data.

## Frozen workload baseline

Rates below use `echoed * 1000 / wall_elapsed_ms` for each run. MAD is the median absolute deviation of those seven rates, in echo/s. The p99 column is only the median *coarse*, power-of-two `p99_us~` output; it cannot prove a fine tail-latency improvement.

| Workload | `/n` | Sessions | Median echo/s | MAD echo/s | Wall-time range (ms) | Coarse p99 µs~ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TCP 128B `/k 1` | 6,400,000 | 256 | 256,925 | 6,181 | 24,648–27,430 | 1,024 |
| TCP 4096B `/k 8` | 25,600,000 | 256 | 1,252,691 | 14,601 | 20,169–21,153 | 2,048 |
| TCP 128B `/k 1` | 3,200,000 | 1,024 | 238,095 | 812 | 13,434–13,610 | 4,096 |
| TCP 128B `/k 1` | 3,200,000 | 4,096 | 210,859 | 4,341 | 14,814–15,495 | 16,384 |
| UDP 1200B | 3,200,000 | 256 | 166,684 | 8,253 | 18,561–21,005 | 1,024 |
| UDP 65507B | 800,000 | 256 | 67,511 | 1,759 | 11,610–17,883 | 4,096 |

Server settings: TCP `/threads 8 /cq 65536 /memory 2147483648 /rio-buffer 65507`; UDP `/k 4096 /rio-buffer 65507 /cq 65536 /memory 2147483648`. Client workload settings: `/threads 8 /cq 65536 /memory 2147483648 /b 0 /t 30 /q /stats`; payloads use `/z`; TCP `/k` and `/c` are shown above. Local port is selected dynamically; each exact port and command appears in the raw run.

## Informative C++ reference and profile limitation

The separately built C++ client (`10d1d7dcb2c69dab252dda5c49f317136f27efc9`, SHA-256 `cc1da02d9455a27509068ccf5439b92bdfb3e6fe4851bb92a2804ceb79ade80a`) completed one valid run of each primary case against the same Zig server build: TCP 128B 30,596 ms, TCP 4096B `/k 8` 33,564 ms, UDP 1200B 28,698 ms, UDP 65507B 17,843 ms. Single runs are not statistical C++/Zig comparisons and are not a Zig-source acceptance baseline.

Windows Performance Recorder CPU sampling was attempted but `wpr -start CPU -filemode` returned `0xc5585011` (“Failed to enable the policy to profile system performance”); no ETW CPU trace was produced. Run-level process CPU time is recorded, but it does not identify shared-metrics, CQ, timer, or validation hotspots. Therefore no profile-gated hot-path candidate is approved by this baseline alone. The Task 2 benchmark-only finer histogram must be applied identically to baseline and candidates before a fine p99/p999 claim.

For candidate acceptance, compare the same peer, frozen manifest, compiler, and instrumentation mode with at least seven A/B/A runs. A median gain must exceed `max(0.05 × baseline median, 3 × baseline MAD)` in the measured metric's units, with no meaningful throughput or p99/p999 regression in another required workload. Report inconclusive variance rather than choosing the best run.

## Implementation checkpoint after structural tasks

- The opt-in 4096-bucket worker-owned histogram was added at `557cc03`; ReleaseFast `-Dbench-histogram=true` baseline binary SHA-256 is `a2e905f2a215fdae9ebd1e4059f83fe6322ed46af3f650ed2db2216a217db72a` at `zig-out/bench/instrumented-557cc03/bin/zig-echo-client.exe`. The ordinary `report`/`final` fields are unchanged. Process tests establish 17 logical TCP echoes at `/k 8` produce 3 completed-batch samples, while 13 UDP echoes produce 13 samples.
- Structural commits: typed resource ownership `21499fc`, session transitions `9afee6a`, and worker lifecycle `515a0a6`. Debug and ReleaseFast self-contained suites, fault and external-stop cases, and TCP/UDP interoperability with both an independently built Zig server and a C++ server passed after Task 5. Tests include staged pre-publication rollback and an armed CQ with an outstanding operation.
- Task 6 — **SKIPPED: no contention evidence.** Windows Performance Recorder was retried after Task 5. `wpr -status` reported no recording, and `wpr -start CPU -filemode` again failed with `0xc5585011` (system-performance profiling policy). There is no function-level trace showing shared-metrics cache-line contention. The global metrics layout and source hot path are therefore unchanged. Run-level CPU time and throughput cannot substitute for this profile gate.
- The structural commits are correctness-validated, not accepted as a throughput or tail-latency improvement. The pre-refactor measurements above used a non-instrumented binary and must not be compared as a fine-tail A/B result with the instrumented binary. A same-instrumentation post-refactor A/B/A series remains a separate performance acceptance gate.
