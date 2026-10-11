# Zig client parity contract (audit baseline)

Frozen from the four C++/Rust commits and the Zig commit listed below. Where C++ and Rust already
agree, that agreement is the authority; the Rust client is the architecture template.

| Source | Revision |
| --- | --- |
| cpp-echo-client | `fe9ea9b` Fix concurrent RIO registrations and completion-stop arbitration |
| cpp-echo-server | `63cee82` Isolate RIO slots and enforce page-rounded UDP budgets |
| rust-echo-client | `f058d0f` Settle acquired completions before control deadlines |
| rust-echo-server | `0080695` Enforce UDP page budgets and native acceptor regressions |
| zig-echo-client (before) | `15db0fa` Count the run quota per session when reporting unclaimed echoes |

## 1. Module map (9 files, one for one with the Rust client)

| Zig | Rust | Responsibility |
| --- | --- | --- |
| `main.zig` | `main.rs` | entry point, console signal, exit code |
| `root.zig` | `lib.rs` | module exports |
| `types.zig` | `types.rs` | protocol, exit codes, options, capacities, checked arithmetic |
| `contract.zig` | `contract.rs` | command line, diagnostic tokens, capacity budgets, classification |
| `native.zig` | `native.rs` | Windows ABI, Winsock, RIO, ConnectEx, every resource owner |
| `engine.zig` | `engine.rs` | native data path, worker start and stop, run coordination |
| `internal.zig` | `internal.rs` | session, scheduler, worker, timer, trace |
| `metrics.zig` | `metrics.rs` | statistics ledger, latency histogram, terminal line |
| `payload.zig` | `payload.rs` | payload construction and byte-exact verification |

Dependency direction: `types` <- `payload`, `metrics` <- `contract` <- `native` <- `internal` <- `engine` <- `main`.
`native.zig` never imports a state machine; the source-policy gate enforces this.

## 2. Command line contract

Accepted switches and ranges, with the explicit zeros the reference accepts:

| Switch | Range | Scope |
| --- | --- | --- |
| `/p` | `tcp` or `udp` | both |
| `/r` | 1..65535 | both |
| `/l` | 0..65535 | both |
| `/n` | 0..u64::MAX, 0 means unlimited | both |
| `/t` | 1..u32::MAX | both |
| `/i` | 0..u32::MAX, 0 disables pacing | both |
| `/d` `/z` `/zt` | literal (<= 32767 UTF-16 units) or 1..67108864 | both |
| `/k` | 1..65536 | TCP only |
| `/c` | 1..1048576 | both |
| `/threads` | 0..64, 0 means automatic | both |
| `/w` | 0..u32::MAX, 0 disables the run deadline | both |
| `/rc` | 0..u32::MAX, 0 means reconnect immediately | both |
| `/report` | 0..u32::MAX, 0 disables reporting | both |
| `/b` | 0..2147483647 | both |
| `/cq` | 64..1048576 | both |
| `/memory` | 1048576..u64::MAX | both |

Diagnostic tokens, in precedence order after the switches are consumed:

1. `out-of-range` when the worker split exceeds the session count
2. `missing-target`
3. `unexpected-target`
4. `missing-protocol`
5. `conflicting-payload`
6. `protocol-option` (pipeline switch with UDP)
7. `local-port-conflict`
8. `quota-overflow`
9. `invalid-utf16` for a literal payload
10. `payload-size` (UDP datagram limit, or a batch over 67108864)
11. `memory-capacity`
12. `cq-capacity`

`/h` suppresses only items 2 and 4. Earlier tokens: `unknown-switch`, `unexpected-value`,
`missing-value`, `invalid-number`, `invalid-utf16` on a raw argument.

Exit codes: 0 success, 1 usage, 2 network, 3 echo failure, 4 internal.

## 3. Session and scheduler state machine

States: `dormant -> connecting -> active -> pacing -> closing -> reconnecting -> done`.

- `/n` is a **per-session** quota. A claim is trimmed to the remaining grant and a grant is never
  refunded, so a reconnect only claims what the run has left.
- One attempt is one receive plus one send whatever the pipeline depth is; the native request queue
  depth is 1 receive and 1 send per session.
- `closing` is the first phase of generation retirement: the socket is closed, but the request
  queue and the registered windows stay valid until every completion of that generation has been
  dequeued. Only then does `reconnecting` or `done` follow.
- Every request context carries the session index **and** the transport generation, so a completion
  of a retired generation is retired from the ledger but never steers the live state machine.
- A failed generation settles the attempt's whole quota as lost exactly once.

## 4. Completion arbitration order

Per worker iteration:

1. acquire one IOCP packet (notification, ConnectEx completion, or control packet)
2. drain the RIO completion queue in bounded batches and apply every completion
3. evaluate the controlled stop or the run deadline
4. expire due session timers
5. re-arm `RIONotify` only while work is in flight
6. leave the loop when the terminal condition holds

Even an already-due stop or deadline permits one bounded zero-wait drain: queued completions are
never skipped, and the drain never runs ahead of the control path.

## 5. Native ownership invariants

- One `VirtualAlloc` per worker; TX windows first, then RX windows, each slot disjoint.
- **One registration per TX window**: the documented RIOSend contract forbids using any other part
  of a registration while its send is pending, even when the parts would be disjoint.
- **One registration for the whole RX region**: RIOReceive permits independent receives in
  non-overlapping parts of one registration.
- A partial send re-posts the remainder of the same window, so one attempt stays one outstanding
  `RIOSend`.
- Release order: retire outstanding operations -> close the completion queue and its notification
  state -> deregister every buffer -> `VirtualFree` the single page owner -> free host arrays ->
  close the completion port.
- Release requires `outstanding == 0`; a provider that never retires an operation is a hard failure
  rather than a silent unmap of memory it still references.

## 6. Statistics ledger

`attempted = pending + echoed + corrupted + lost + cancelled` is preserved at every observation
point. A controlled stop moves unfinished attempts to `cancelled`; a fatal end moves them to
`lost`. Terminal line field order:

```
elapsed_ms sessions active attempted pending echoed corrupted lost cancelled sent_bytes
received_bytes bytes connections reconnects network_errors echo_per_sec MiB_per_sec
p50_us~ p99_us~ p999_us~ mean_us max_us~ latency_sample=batch
```

Latency is sampled once per completed batch, bucketed by the power of two below the sample, with
zero and sub-microsecond samples counting as one microsecond.

## 7. Clock

Deadlines are absolute **QPC ticks**. Millisecond durations are converted once at worker start,
rounding up so a deadline is never shortened; only the blocking IOCP wait is rounded back up to
whole milliseconds. `GetTickCount64` is not a deadline source.
