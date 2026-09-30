param(
    [string]$ClientPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-client.exe')
)

$ErrorActionPreference = 'Stop'
$client = (Resolve-Path -LiteralPath $ClientPath).Path

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Start-Peer([string]$protocol, [int]$port, [string]$mode = 'echo') {
    $ready = Join-Path ([IO.Path]::GetTempPath()) ("zig-client-peer-" + [Guid]::NewGuid().ToString('N') + '.txt')
    $script = Join-Path $PSScriptRoot 'loopback_peer.ps1'
    $process = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', "`"$script`"", '-Protocol', $protocol, '-Port', "$port", '-Mode', $mode, '-ReadyPath', "`"$ready`"") -WindowStyle Hidden -PassThru
    $until = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $until) {
        if (Test-Path -LiteralPath $ready) { return [pscustomobject]@{ Process = $process; Ready = $ready } }
        if ($process.HasExited) { throw "peer failed to start: exit=$($process.ExitCode)" }
        Start-Sleep -Milliseconds 25
    }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
    throw 'peer readiness timed out'
}

function Stop-Peer($peer) {
    if ($null -ne $peer) {
        if (-not $peer.Process.HasExited) { Stop-Process -Id $peer.Process.Id -Force }
        $peer.Process.Dispose()
        Remove-Item -LiteralPath $peer.Ready -ErrorAction SilentlyContinue
    }
}

function Invoke-Client([string[]]$arguments, [int]$expectedExit, [string[]]$required, [string[]]$requiredStderr = @()) {
    $id = [Guid]::NewGuid().ToString('N')
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "zig-client-$id-out.txt"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "zig-client-$id-err.txt"
    $process = $null
    try {
        $process = Start-Process -FilePath $client -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force
            throw "client timeout: $($arguments -join ' ')"
        }
        $out = Get-Content -LiteralPath $stdout -Raw
        $err = Get-Content -LiteralPath $stderr -Raw
        if ($null -eq $out) { $out = '' }
        if ($null -eq $err) { $err = '' }
        if ($process.ExitCode -ne $expectedExit) {
            throw "client exit=$($process.ExitCode), expected=$expectedExit; args=$($arguments -join ' '); stdout=$out stderr=$err"
        }
        foreach ($field in $required) {
            if (-not $out.Contains($field)) { throw "missing '$field'; args=$($arguments -join ' '); stdout=$out stderr=$err" }
        }
        foreach ($field in $requiredStderr) {
            if (-not $err.Contains($field)) { throw "missing stderr '$field'; args=$($arguments -join ' '); stdout=$out stderr=$err" }
        }
        if ($expectedExit -eq 0 -and -not [string]::IsNullOrEmpty($err)) { throw "unexpected stderr: $err" }
        return $out
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdout, $stderr -ErrorAction SilentlyContinue
    }
}

[void](Invoke-Client @('/h') 0 @('Usage: zig-echo-client target /p tcp|udp', 'Data I/O is always RIO'))
[void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/d', '') 1 @('Usage: zig-echo-client target /p tcp|udp') @('Invalid arguments:'))

$port = Get-FreePort
$peer = Start-Peer 'udp' $port
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '13', '/c', '8', '/threads', '2', '/zt', '128', '/t', '2', '/stats') 0 @('final ', 'sessions=8', 'echoed=13', 'corrupted=0', 'lost=0', 'network_errors=0', 'bytes=1664', 'latency_sample=batch'))
    [void](Invoke-Client @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '5', '/c', '4', '/threads', '2', '/z', '65507', '/t', '2', '/stats') 0 @('echoed=5', 'lost=0', 'bytes=327535'))
    [void](Invoke-Client @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '4', '/c', '2', '/threads', '2', '/i', '50', '/zt', '128', '/t', '2', '/stats') 0 @('echoed=4', 'lost=0', 'bytes=512'))
    [void](Invoke-Client @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '0', '/c', '1', '/i', '50', '/w', '2', '/report', '1', '/t', '2', '/stats') 0 @('report ', 'final ', 'corrupted=0', 'lost=0'))
} finally { Stop-Peer $peer }

$port = Get-FreePort
$peer = Start-Peer 'tcp' $port
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '17', '/c', '8', '/threads', '2', '/k', '8', '/z', '4096', '/t', '2', '/stats') 0 @('sessions=8', 'echoed=17', 'corrupted=0', 'lost=0', 'network_errors=0', 'bytes=69632', 'latency_sample=batch'))
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '1', '/c', '8', '/threads', '2', '/k', '8', '/zt', '128', '/t', '2', '/stats') 0 @('echoed=1', 'lost=0', 'bytes=128'))
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '0', '/c', '2', '/threads', '2', '/k', '1', '/i', '50', '/zt', '128', '/t', '2', '/w', '1', '/stats') 0 @('final ', 'sessions=2', 'corrupted=0', 'lost=0', 'latency_sample=batch'))
} finally { Stop-Peer $peer }

$port = Get-FreePort
$peer = Start-Peer 'udp' $port 'blackhole'
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '1', '/c', '1', '/t', '1', '/stats') 3 @('echoed=0', 'lost=1', 'network_errors=1'))
} finally { Stop-Peer $peer }

$port = Get-FreePort
$peer = Start-Peer 'tcp' $port 'fragment'
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '8', '/c', '1', '/k', '8', '/z', '4096', '/t', '2', '/stats') 0 @('echoed=8', 'lost=0', 'bytes=32768'))
} finally { Stop-Peer $peer }

$port = Get-FreePort
$peer = Start-Peer 'tcp' $port 'close'
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '8', '/c', '1', '/k', '8', '/z', '4096', '/t', '1', '/stats') 3 @('echoed=0', 'lost=8', 'network_errors=1'))
} finally { Stop-Peer $peer }

$port = Get-FreePort
$peer = Start-Peer 'tcp' $port 'blackhole'
try {
    [void](Invoke-Client @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '0', '/c', '1', '/k', '8', '/z', '4096', '/t', '3', '/w', '1', '/stats') 0 @('final ', 'corrupted=0', 'lost=0', 'latency_sample=batch'))
} finally { Stop-Peer $peer }

$forcedStopDriver = Join-Path (Split-Path -Parent $client) 'zig-echo-client-external-stop-driver.exe'
if (-not (Test-Path -LiteralPath $forcedStopDriver -PathType Leaf)) { throw "Missing forced-stop driver: $forcedStopDriver" }
$port = Get-FreePort
$peer = Start-Peer 'tcp' $port 'blackhole'
try {
    $previousClient = $client
    $client = $forcedStopDriver
    [void](Invoke-Client @("$port") 0 @('final ', 'echoed=0', 'corrupted=0', 'lost=0', 'network_errors=0'))
    $client = $previousClient
} finally {
    $client = $previousClient
    Stop-Peer $peer
}

$port = Get-FreePort
$id = [Guid]::NewGuid().ToString('N')
$stdout = Join-Path ([IO.Path]::GetTempPath()) "zig-client-reconnect-$id-out.txt"
$stderr = Join-Path ([IO.Path]::GetTempPath()) "zig-client-reconnect-$id-err.txt"
$clientProcess = $null
$peer = $null
try {
    $clientProcess = Start-Process -FilePath $client -ArgumentList @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '1', '/c', '1', '/rc', '1', '/t', '1', '/w', '5', '/stats') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Start-Sleep -Milliseconds 1200
    $peer = Start-Peer 'tcp' $port
    if (-not $clientProcess.WaitForExit(10000)) {
        Stop-Process -Id $clientProcess.Id -Force
        throw 'reconnect client timed out'
    }
    $out = Get-Content -LiteralPath $stdout -Raw
    if ($clientProcess.ExitCode -ne 0 -or $out -notmatch 'echoed=1' -or $out -notmatch 'lost=0' -or $out -notmatch 'network_errors=[1-9]') {
        throw "reconnect mismatch: exit=$($clientProcess.ExitCode), stdout=$out, stderr=$(Get-Content -LiteralPath $stderr -Raw)"
    }
} finally {
    Stop-Peer $peer
    if ($null -ne $clientProcess) {
        if (-not $clientProcess.HasExited) { Stop-Process -Id $clientProcess.Id -Force }
        $clientProcess.Dispose()
    }
    Remove-Item -LiteralPath $stdout, $stderr -ErrorAction SilentlyContinue
}

Write-Output 'client process tests passed'
