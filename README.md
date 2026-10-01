# zig-echo-client

Independent Windows TCP/UDP echo client rewritten from `cpp-echo-client` in Zig. All payload operations use Winsock Registered I/O (RIO). Each fixed worker owns one RIO completion queue, its IOCP notification port, registered arena, sessions, request queues, and timer heap. IOCP also receives TCP `ConnectEx` completions and worker stop packets. There is no ordinary `send`/`recv`, `WSAPoll`, `select`, or `std.net` fallback.

The client owns its Win32/RIO/ConnectEx ABI declarations and has no source or build dependency on any server or sibling project. Interoperability tests accept a separately built server executable path.
This pinned Zig 0.17-dev snapshot has removed `@cImport`, so the private native declarations are checked against a Microsoft SDK-compiled ABI probe (sizes, offsets, and constants) in the default test suite.

## Toolchain and build

- Windows x64 and MSVC ABI
- Zig `0.17.0-dev.2375+d8aab4878`
- Visual Studio C++ tools and Windows SDK
- PowerShell 7 for process tests

From this project root:

```powershell
.\build.ps1 Debug
.\build.ps1 ReleaseFast
```

`build.ps1` pins the compiler version, enters the x64 MSVC/SDK environment, builds, and runs the complete self-contained suite. Compiler selection is `-ZigPath`, then `ZIG_EXE`, then the pinned installation directory, then `PATH`; a version mismatch is rejected. `-BuildOnly` omits tests. The executable is `zig-out\bin\zig-echo-client.exe`.

## TCP example

Start an echo server separately, then run a finite test without `/w`:

```powershell
.\zig-out\bin\zig-echo-client.exe 127.0.0.1 `
  /p tcp /r 7000 /n 1000000 /c 256 /threads 8 `
  /k 8 /zt 4096 /t 30 /cq 65536 /memory 2147483648 `
  /report 1 /stats
```

`/n` is the total logical echo count across all sessions. `/k` batches that many TCP messages into one send/receive attempt; the final batch may be smaller. `RIO_MSG_WAITALL` waits for the whole TCP batch. Partial sends are reposted against the remaining registered buffer region. `ConnectEx` is associated with the worker IOCP before connection; the RIO request queue is created only after a successful connection completion.

## UDP example

```powershell
.\zig-out\bin\zig-echo-client.exe 127.0.0.1 `
  /p udp /r 7000 /n 100000 /c 128 /threads 8 `
  /z 1200 /t 5 /cq 4096 /stats
```

Each connected UDP session owns one RIO request queue. It posts a receive and send for each claimed echo. The maximum UDP payload is 65507 bytes. `/d text`, `/z bytes`, and `/zt bytes` select mutually exclusive payload patterns. `/i milliseconds` paces attempts, `/rc [seconds]` enables reconnects, and `/w seconds` requests a finite run; omitting `/w` leaves a finite `/n` test to complete naturally. `/n 0` is unbounded and therefore needs `/w` or console stop for a bounded test.

`/report seconds` emits periodic shared metrics; `/stats` prints a final line even with `/q`. Successful metrics go to stdout, errors to stderr. `echoed`, `corrupted`, and `lost` count logical echoes, whereas `bytes` counts successful echoed payload bytes. Latency samples are per completed batch, not per logical echo. Exit codes are 0 success/controlled stop, 1 usage, 2 network setup/no echo, 3 echo failure/loss, and 4 broken internal invariant.

## Verification

The default build suite is self-contained: parser/payload contracts, heap model, Microsoft SDK ABI/ownership checks, local TCP/UDP process cases (including 65507-byte datagrams, fragmented TCP echoes, reconnect, timeout, run-duration and externally requested cancellation drain), deterministic exit-4 fault guards, and source-policy checks.

To test this client against an independently built C++ or Zig server, pass the executable explicitly:

```powershell
pwsh -NoProfile -File .\tests\interoperability.ps1 `
  -ServerPath ..\cpp-echo-server\build\release\cpp-echo-server.exe

pwsh -NoProfile -File .\tests\interoperability.ps1 `
  -ServerPath ..\zig-echo-server\zig-out\bin\zig-echo-server.exe
```

These loopback checks establish functional parity, not a hardware throughput or tail-latency ceiling. Extreme-concurrency claims require measurement on the target CPU, NUMA layout, NIC/RSS topology, and intended network under sustained load.
