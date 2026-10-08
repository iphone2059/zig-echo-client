param(
    [Parameter(Mandatory = $true)][string]$ServerPath,
    [string]$ClientPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-client.exe')
)

$ErrorActionPreference = 'Stop'
$server = (Resolve-Path -LiteralPath $ServerPath).Path
$client = (Resolve-Path -LiteralPath $ClientPath).Path

function Get-FreePort([string]$protocol) {
    if ($protocol -eq 'udp') {
        $socket = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        try { return ([System.Net.IPEndPoint]$socket.Client.LocalEndPoint).Port }
        finally { $socket.Dispose() }
    }
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Invoke-ClientCase([string[]]$arguments, [string[]]$expected) {
    $id = [Guid]::NewGuid().ToString('N')
    $outPath = Join-Path ([IO.Path]::GetTempPath()) "zig-interop-client-$id-out.txt"
    $errPath = Join-Path ([IO.Path]::GetTempPath()) "zig-interop-client-$id-err.txt"
    $process = $null
    try {
        $process = Start-Process -FilePath $client -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        if (-not $process.WaitForExit(10000)) {
            Stop-Process -Id $process.Id -Force
            throw "client timed out: $($arguments -join ' ')"
        }
        $out = Get-Content -LiteralPath $outPath -Raw
        $err = Get-Content -LiteralPath $errPath -Raw
        if ($process.ExitCode -ne 0 -or $err.Length -ne 0) {
            throw "client failed: exit=$($process.ExitCode), stdout=$out, stderr=$err"
        }
        foreach ($field in $expected) {
            if (-not $out.Contains($field)) { throw "missing '$field' in $out" }
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $outPath, $errPath -ErrorAction SilentlyContinue
    }
}

foreach ($protocol in @('tcp', 'udp')) {
    $port = Get-FreePort $protocol
    $id = [Guid]::NewGuid().ToString('N')
    $outPath = Join-Path ([IO.Path]::GetTempPath()) "zig-interop-server-$id-out.txt"
    $errPath = Join-Path ([IO.Path]::GetTempPath()) "zig-interop-server-$id-err.txt"
    $serverArguments = if ($protocol -eq 'tcp') {
        @('/p', 'tcp', '/s', "$port", '/threads', '2', '/cq', '4096', '/w', '5', '/q', '/stats')
    } else {
        @('/p', 'udp', '/s', "$port", '/k', '16', '/rio-buffer', '65507', '/cq', '4096', '/w', '5', '/q', '/stats')
    }
    $process = $null
    try {
        $process = Start-Process -FilePath $server -ArgumentList $serverArguments -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        Start-Sleep -Milliseconds 400
        if ($process.HasExited) { throw "server exited before acceptance: $($process.ExitCode); $(Get-Content -LiteralPath $errPath -Raw)" }
        if ($protocol -eq 'tcp') {
            Invoke-ClientCase @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '17', '/c', '8', '/threads', '2', '/k', '8', '/z', '4096', '/t', '2', '/stats') @('echoed=17', 'corrupted=0', 'lost=0', 'network_errors=0', 'bytes=69632')
            Invoke-ClientCase @('127.0.0.1', '/p', 'tcp', '/r', "$port", '/n', '1', '/c', '8', '/threads', '2', '/k', '8', '/zt', '128', '/t', '2', '/stats') @('echoed=1', 'lost=0', 'bytes=128')
        } else {
            Invoke-ClientCase @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '13', '/c', '8', '/threads', '2', '/z', '1200', '/t', '2', '/stats') @('echoed=13', 'corrupted=0', 'lost=0', 'network_errors=0', 'bytes=15600')
            Invoke-ClientCase @('127.0.0.1', '/p', 'udp', '/r', "$port", '/n', '5', '/c', '4', '/threads', '2', '/z', '65507', '/t', '2', '/stats') @('echoed=5', 'corrupted=0', 'lost=0', 'network_errors=0', 'bytes=327535')
        }
        if (-not $process.WaitForExit(8000)) {
            Stop-Process -Id $process.Id -Force
            throw "server did not terminate at /w: $protocol"
        }
        $out = Get-Content -LiteralPath $outPath -Raw
        $err = Get-Content -LiteralPath $errPath -Raw
        if ($process.ExitCode -ne 0 -or $err.Length -ne 0 -or -not $out.Contains("final protocol=$protocol")) {
            throw "server terminal mismatch: exit=$($process.ExitCode), stdout=$out, stderr=$err"
        }
        if ($protocol -eq 'tcp' -and -not $out.Contains('active=0')) { throw "TCP active sessions remain: $out" }
    } finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            $process.Dispose()
        }
        Remove-Item -LiteralPath $outPath, $errPath -ErrorAction SilentlyContinue
    }
}

Write-Output "client interoperability passed against $server"
