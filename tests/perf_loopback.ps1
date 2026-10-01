param(
    [Parameter(Mandatory = $true)][string]$ClientPath,
    [Parameter(Mandatory = $true)][string]$PeerPath,
    [Parameter(Mandatory = $true)][int]$PeerPid,
    [Parameter(Mandatory = $true)][string[]]$PeerArguments,
    [Parameter(Mandatory = $true)][string]$ExpectedPeerSha256,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
    [string]$HostAddress = '127.0.0.1',
    [Parameter(Mandatory = $true)][string]$Case,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Label,
    [long]$EchoCountOverride = 0,
    [switch]$DescribeOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'perf_commands.ps1')

$manifestPath = Join-Path $PSScriptRoot 'perf_workloads.json'
$cases = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
$selected = @($cases | Where-Object { $_.name -ceq $Case })
if ($selected.Count -ne 1) { throw "benchmark case not found or duplicated: $Case" }
$workload = $selected[0].PSObject.Copy()
if ($EchoCountOverride -lt 0) { throw 'pilot echo-count override must be positive' }
if ($EchoCountOverride -gt 0) { $workload.echo_count = $EchoCountOverride }
$clientArguments = @(New-ClientArguments -Case $workload -Port $Port -HostAddress $HostAddress)
if ($DescribeOnly) {
    [pscustomobject]@{ case = $Case; arguments = [string[]]$clientArguments }
    return
}
if ($Label -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'label must contain only letters, digits, _ or -' }

$clientExe = (Resolve-Path -LiteralPath $ClientPath -ErrorAction Stop).Path
$peerExe = (Resolve-Path -LiteralPath $PeerPath -ErrorAction Stop).Path
$peerProcess = Get-Process -Id $PeerPid -ErrorAction Stop
try {
    $runningPath = [IO.Path]::GetFullPath($peerProcess.Path)
    if (-not [string]::Equals($runningPath, [IO.Path]::GetFullPath($peerExe), [StringComparison]::OrdinalIgnoreCase)) {
        throw "peer process $PeerPid is not $peerExe"
    }
    $peerHash = (Get-FileHash -LiteralPath $peerExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::Equals($peerHash, $ExpectedPeerSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'peer executable SHA-256 changed'
    }
} finally {
    $peerProcess.Dispose()
}

$runId = '{0}-{1}-{2}-{3}' -f $Label, $Case, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $OutputDirectory $runId
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$stdoutPath = Join-Path $runDirectory 'stdout.txt'
$stderrPath = Join-Path $runDirectory 'stderr.txt'
$metadataPath = Join-Path $runDirectory 'run.json'

$timer = [Diagnostics.Stopwatch]::StartNew()
$process = Start-Process -FilePath $clientExe -ArgumentList $clientArguments -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
$timedOut = $false
try {
    if (-not $process.WaitForExit(600000)) {
        $timedOut = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    $timer.Stop()
    $cpuMilliseconds = try { [math]::Round($process.TotalProcessorTime.TotalMilliseconds, 3) } catch { $null }
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
} finally {
    $process.Dispose()
}

$stdout = Get-Content -LiteralPath $stdoutPath -Raw
$stderr = Get-Content -LiteralPath $stderrPath -Raw
$final = @(($stdout -split "`r?`n") | Where-Object { $_ -match '^final ' } | Select-Object -Last 1)
$fields = @{}
if ($final.Count -eq 1) {
    foreach ($matchValue in [regex]::Matches($final[0], '([A-Za-z_]+)=([^\s]+)')) {
        $fields[$matchValue.Groups[1].Value] = $matchValue.Groups[2].Value
    }
}
$expectedBytes = [long]$workload.echo_count * [long]$workload.payload_bytes
$run = [pscustomobject]@{
    exit_code = $exitCode
    elapsed_ms = [long]$timer.ElapsedMilliseconds
    process_cpu_ms = $cpuMilliseconds
    echoed = if ($fields.ContainsKey('echoed')) { [long]$fields.echoed } else { -1 }
    expected_echo_count = [long]$workload.echo_count
    bytes = if ($fields.ContainsKey('bytes')) { [long]$fields.bytes } else { -1 }
    expected_bytes = $expectedBytes
    lost = if ($fields.ContainsKey('lost')) { [long]$fields.lost } else { -1 }
    corrupted = if ($fields.ContainsKey('corrupted')) { [long]$fields.corrupted } else { -1 }
    network_errors = if ($fields.ContainsKey('network_errors')) { [long]$fields.network_errors } else { -1 }
    peer_sha256 = $peerHash
    client_sha256 = (Get-FileHash -LiteralPath $clientExe -Algorithm SHA256).Hash.ToLowerInvariant()
    client_commit = Get-ExecutableCommit -Path $clientExe
    peer_commit = Get-ExecutableCommit -Path $peerExe -AllowUnknown
    client_path = $clientExe
    peer_path = $peerExe
    peer_pid = $PeerPid
    host_address = $HostAddress
    client_arguments = $clientArguments
    peer_arguments = $PeerArguments
    case = $workload
    reported_elapsed_ms = if ($fields.ContainsKey('elapsed_ms')) { [long]$fields.elapsed_ms } else { -1 }
    zig_version = (& 'C:\bin\zig-x86_64-windows-0.17.0-dev.2375+d8aab4878\zig.exe' version | Out-String).Trim()
    windows_version = [Environment]::OSVersion.VersionString
    processor = @(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name -Unique)
    stdout_path = $stdoutPath
    stderr_path = $stderrPath
    stderr_length = $stderr.Length
    timed_out = $timedOut
}
$run | Add-Member -NotePropertyName valid -NotePropertyValue ((Test-BenchmarkRun -Run $run -ExpectedPeerSha256 $ExpectedPeerSha256) -and $stderr.Length -eq 0)
$run | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding utf8
Write-Output "benchmark_run=$metadataPath valid=$($run.valid) elapsed_ms=$($run.elapsed_ms) echoed=$($run.echoed)"
if (-not $run.valid) { throw "invalid benchmark run; inspect $metadataPath" }
