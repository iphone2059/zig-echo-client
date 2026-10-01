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
        [Parameter(Mandatory = $true)][string]$ExpectedPeerSha256
    )

    $required = @('exit_code','elapsed_ms','echoed','expected_echo_count','bytes','expected_bytes',
        'lost','corrupted','network_errors','peer_sha256')
    foreach ($field in $required) {
        if ($null -eq $Run.PSObject.Properties[$field]) { return $false }
    }
    return $Run.exit_code -eq 0 -and $Run.elapsed_ms -ge 10000 -and
        $Run.echoed -eq $Run.expected_echo_count -and $Run.bytes -eq $Run.expected_bytes -and
        $Run.lost -eq 0 -and $Run.corrupted -eq 0 -and $Run.network_errors -eq 0 -and
        [string]::Equals($Run.peer_sha256, $ExpectedPeerSha256, [StringComparison]::OrdinalIgnoreCase)
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
