# zig-echo-client — Zig 0.17-dev + Microsoft Windows SDK

First executable migration slice of the supplied `cpp-echo-client`.

Implemented:

- Direct Microsoft Windows SDK header import.
- RIO extension table through `WSAIoctl`.
- Connected UDP RIO sockets, one RQ per session.
- Shared registered `VirtualAlloc` arena; send/receive region per session.
- RIO CQ -> IOCP notification and explicit re-arm tracking.
- Simultaneous receive + send per attempt.
- Byte-for-byte payload verification.
- UTF-8 literal `/d`, binary `/z`, printable `/zt` patterns.
- Finite `/n`, multiple UDP sessions on one worker CQ, operation timeout/pacing via indexed heap.
- QPC latency + 64-bin log2 histogram.
- Shutdown cancellation/drain and exit-code separation.

Not enabled in this first slice: TCP/ConnectEx, reconnect, multi-worker partitioning. They are intentionally rejected rather than silently mapped to normal `send/recv`.

## Build

Use Zig `0.17.0-dev.2320+1e770dbef`, VS 2022, and a current Windows SDK. In Developer PowerShell:

```powershell
.\build.ps1 ReleaseFast
```

or:

```powershell
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast
```

## Run against the Zig server

Server:

```powershell
.\zig-out\bin\zig-echo-server.exe /p udp /s 7000 /k 4096 /cq 8192 /stats
```

Client:

```powershell
.\zig-out\bin\zig-echo-client.exe 127.0.0.1 /p udp /r 7000 /c 128 /n 100000 /z 1200 /cq 4096 /stats
```


> Validation note: this package was source-reviewed in a non-Windows environment; run the first build in VS 2022 Developer PowerShell so Microsoft SDK `@cImport` translation is validated by Zig on the target machine.
