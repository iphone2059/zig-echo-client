function New-ClientArguments {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Case,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$HostAddress = '127.0.0.1'
    )

    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($HostAddress, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'benchmark peer address must be IPv4'
    }

    $required = @('protocol','payload_bytes','pipeline_depth','sessions','threads','cq','memory_bytes','socket_buffer_bytes','echo_count')
    foreach ($field in $required) {
        if ($null -eq $Case.PSObject.Properties[$field]) { throw "benchmark case lacks $field" }
    }
    $protocol = [string]$Case.protocol
    $payload = [long]$Case.payload_bytes
    $pipeline = [long]$Case.pipeline_depth
    $sessions = [long]$Case.sessions
    $threads = [long]$Case.threads
    $cq = [long]$Case.cq
    $memory = [long]$Case.memory_bytes
    $socketBuffer = [long]$Case.socket_buffer_bytes
    $count = [long]$Case.echo_count
    if ($Port -lt 1 -or $Port -gt 65535 -or $protocol -cnotin @('tcp','udp') -or
        $payload -lt 1 -or $payload -gt 65507 -or $pipeline -lt 1 -or
        $sessions -lt 1 -or $sessions -gt 1048576 -or $threads -lt 1 -or $threads -gt 64 -or
        $cq -lt 64 -or $cq -gt 1048576 -or $memory -lt 1048576 -or
        $socketBuffer -lt 0 -or $socketBuffer -gt [int]::MaxValue -or $count -lt 1) {
        throw 'benchmark case has an invalid value'
    }
    if ($protocol -ceq 'udp' -and $pipeline -ne 1) { throw 'UDP requires pipeline depth 1' }
    if ($protocol -ceq 'tcp' -and $payload * $pipeline -gt 67108864) { throw 'TCP batch exceeds 64 MiB' }
    if ($memory -lt 2 * $payload * $pipeline * $sessions) { throw 'registered memory is too small' }

    $arguments = @(
        $HostAddress,'/p',$protocol,'/r',[string]$Port,'/n',[string]$count,
        '/c',[string]$sessions,'/threads',[string]$threads
    )
    if ($protocol -ceq 'tcp') { $arguments += @('/k',[string]$pipeline) }
    $arguments += @('/z',[string]$payload,'/t','30','/cq',[string]$cq,
        '/memory',[string]$memory,'/b',[string]$socketBuffer,'/q','/stats')
    return [string[]]$arguments
}

function Test-BenchmarkRun {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Run,
        [Parameter(Mandatory = $true)][string]$ExpectedPeerSha256,
        # A formal performance gate must prove the mode, not merely recognise it.
        [string]$RequiredOptimizeMode = 'ReleaseFast'
    )

    $required = @('exit_code','elapsed_ms','echoed','expected_echo_count','bytes','expected_bytes',
        'lost','corrupted','network_errors','peer_sha256','optimize_mode')
    foreach ($field in $required) {
        if ($null -eq $Run.PSObject.Properties[$field]) { return $false }
    }
    return $Run.exit_code -eq 0 -and $Run.elapsed_ms -ge 10000 -and
        $Run.echoed -eq $Run.expected_echo_count -and $Run.bytes -eq $Run.expected_bytes -and
        $Run.lost -eq 0 -and $Run.corrupted -eq 0 -and $Run.network_errors -eq 0 -and
        [string]::Equals($Run.peer_sha256, $ExpectedPeerSha256, [StringComparison]::OrdinalIgnoreCase) -and
        $Run.optimize_mode -cin @('Debug', 'ReleaseFast') -and
        ($RequiredOptimizeMode -ceq '' -or $Run.optimize_mode -ceq $RequiredOptimizeMode)
}

function Get-ExecutableBuildManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $manifestPath = Join-Path $directory 'build-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "executable build manifest missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.optimize_mode -cnotin @('Debug', 'ReleaseFast')) {
        throw "invalid optimize mode in build manifest: $manifestPath"
    }
    if ($null -eq $manifest.binaries) { throw "build manifest records no binaries: $manifestPath" }
    return $manifest
}

# A marker beside the executable only proves what the build intended. The manifest records the hash of
# every installed binary as well, so an executable swapped in afterwards is refused rather than
# measured under an identity it does not have.
function Assert-ExecutableIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RequiredOptimizeMode = ''
    )

    $full = [IO.Path]::GetFullPath($Path)
    $manifest = Get-ExecutableBuildManifest -Path $full
    $name = Split-Path -Leaf $full
    $recorded = $manifest.binaries.PSObject.Properties[$name]
    if ($null -eq $recorded) { throw "executable is not recorded in the build manifest: $name" }
    $observed = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::Equals($observed, [string]$recorded.Value, [StringComparison]::OrdinalIgnoreCase)) {
        throw "executable does not match its build manifest: $full"
    }
    if ($RequiredOptimizeMode -cne '' -and $manifest.optimize_mode -cne $RequiredOptimizeMode) {
        throw "executable was built as $($manifest.optimize_mode); $RequiredOptimizeMode is required for this gate"
    }
    return $manifest
}

function Get-ExecutableOptimizeMode {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AllowUnknown)

    try { return (Get-ExecutableBuildManifest -Path $Path).optimize_mode }
    catch {
        if ($AllowUnknown) { return $null }
        throw
    }
}

function Get-WorkloadTotals {
    param([Parameter(Mandatory = $true)][pscustomobject]$Case)

    # /n is the per-session echo quota and /c is the session count, so a complete finite load is
    # echo_count * sessions echoes and that many payload bytes. Deriving the total from echo_count
    # alone rejects a run that did exactly what it was asked to do.
    foreach ($field in @('echo_count', 'sessions', 'payload_bytes')) {
        if ($null -eq $Case.PSObject.Properties[$field]) { throw "benchmark case lacks $field" }
    }
    $perSession = [long]$Case.echo_count
    $sessions = [long]$Case.sessions
    $payload = [long]$Case.payload_bytes
    if ($perSession -lt 1 -or $sessions -lt 1 -or $payload -lt 1) { throw 'benchmark case totals require positive values' }
    return [pscustomobject]@{
        per_session_echoes = $perSession
        sessions = $sessions
        echoes = $perSession * $sessions
        bytes = $perSession * $sessions * $payload
    }
}

function Get-ExecutableCommit {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AllowUnknown)

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $marker = Join-Path $directory 'source-commit.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        if ($AllowUnknown) { return $null }
        throw "executable source commit marker missing: $marker"
    }
    $commit = (Get-Content -LiteralPath $marker -Raw).Trim()
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw "invalid executable source commit marker: $marker" }
    return $commit
}
