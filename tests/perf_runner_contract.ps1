$ErrorActionPreference = 'Stop'
$commands = Join-Path $PSScriptRoot 'perf_commands.ps1'
if (Test-Path -LiteralPath $commands -PathType Leaf) { . $commands }

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

Assert-True ($null -ne (Get-Command New-ClientArguments -ErrorAction SilentlyContinue)) 'New-ClientArguments is missing'
Assert-True ($null -ne (Get-Command Test-BenchmarkRun -ErrorAction SilentlyContinue)) 'Test-BenchmarkRun is missing'
Assert-True ($null -ne (Get-Command Get-ExecutableCommit -ErrorAction SilentlyContinue)) 'Get-ExecutableCommit is missing'

$tcp = [pscustomobject]@{
    name = 'tail'; protocol = 'tcp'; payload_bytes = 128; pipeline_depth = 8
    sessions = 8; threads = 2; cq = 4096; memory_bytes = 2147483648
    socket_buffer_bytes = 0; echo_count = 17
}
$tcpArgs = @(New-ClientArguments -Case $tcp -Port 7000)
$expectedTcp = @('127.0.0.1','/p','tcp','/r','7000','/n','17','/c','8','/threads','2','/k','8','/z','128','/t','30','/cq','4096','/memory','2147483648','/b','0','/q','/stats')
Assert-True (($tcpArgs -join '|') -ceq ($expectedTcp -join '|')) "wrong TCP arguments: $($tcpArgs -join ' ')"
Assert-True (-not ($tcpArgs -contains '/w')) 'benchmark client must not have /w'
$alternateHost = @(New-ClientArguments -Case $tcp -Port 7000 -HostAddress '127.0.0.2')
Assert-True ($alternateHost[0] -ceq '127.0.0.2') 'explicit peer IPv4 address ignored'

$udp = [pscustomobject]@{
    name = 'udp_max'; protocol = 'udp'; payload_bytes = 65507; pipeline_depth = 1
    sessions = 1; threads = 1; cq = 4096; memory_bytes = 2147483648
    socket_buffer_bytes = 0; echo_count = 100000
}
$udpArgs = @(New-ClientArguments -Case $udp -Port 7001)
Assert-True ($udpArgs -contains '65507') 'UDP maximum payload missing'
Assert-True (-not ($udpArgs -contains '/k')) 'UDP must not have /k'
Assert-True (-not ($udpArgs -contains '/w')) 'UDP benchmark client must not have /w'

$bad = $tcp.PSObject.Copy()
$bad.echo_count = 0
$threw = $false
try { $null = New-ClientArguments -Case $bad -Port 7000 } catch { $threw = $true }
Assert-True $threw 'zero finite count must be rejected'

$run = [pscustomobject]@{
    exit_code = 0; elapsed_ms = 10000; echoed = 17; expected_echo_count = 17
    bytes = 2176; expected_bytes = 2176; lost = 0; corrupted = 0
    network_errors = 0; peer_sha256 = ('a' * 64)
}
Assert-True (Test-BenchmarkRun -Run $run -ExpectedPeerSha256 ('a' * 64)) 'valid run rejected'
foreach ($mutation in @(
    @{ field = 'exit_code'; value = 3 },
    @{ field = 'elapsed_ms'; value = 9999 },
    @{ field = 'echoed'; value = 16 },
    @{ field = 'bytes'; value = 2175 },
    @{ field = 'lost'; value = 1 },
    @{ field = 'corrupted'; value = 1 },
    @{ field = 'network_errors'; value = 1 },
    @{ field = 'peer_sha256'; value = ('b' * 64) }
)) {
    $candidate = $run.PSObject.Copy()
    $candidate.($mutation.field) = $mutation.value
    Assert-True (-not (Test-BenchmarkRun -Run $candidate -ExpectedPeerSha256 ('a' * 64))) "invalid run accepted: $($mutation.field)"
}

$runner = Join-Path $PSScriptRoot 'perf_loopback.ps1'
Assert-True (Test-Path -LiteralPath $runner -PathType Leaf) 'perf_loopback.ps1 is missing'
$nonexistentOutput = Join-Path ([IO.Path]::GetTempPath()) ('zig-client-perf-describe-' + [guid]::NewGuid().ToString('N'))
$described = & $runner -ClientPath 'missing-client.exe' -PeerPath 'missing-server.exe' -PeerPid 0 `
    -PeerArguments @('/p','tcp','/s','7000') -ExpectedPeerSha256 ('a' * 64) -Port 7000 `
    -Case 'tcp_128_k1' -OutputDirectory $nonexistentOutput -Label 'dry-run' -DescribeOnly
Assert-True ($described.arguments -contains '/n') 'describe-only command lacks finite /n'
Assert-True (-not ($described.arguments -contains '/w')) 'describe-only command added /w'
Assert-True (-not (Test-Path -LiteralPath $nonexistentOutput)) 'describe-only created output directory'
$pilot = & $runner -ClientPath 'missing-client.exe' -PeerPath 'missing-server.exe' -PeerPid 0 `
    -PeerArguments @('/p','tcp','/s','7000') -ExpectedPeerSha256 ('a' * 64) -Port 7000 `
    -Case 'tcp_128_k1' -OutputDirectory $nonexistentOutput -Label 'dry-run' -DescribeOnly -EchoCountOverride 200000
$countIndex = [array]::IndexOf($pilot.arguments, '/n')
Assert-True ($countIndex -ge 0 -and $pilot.arguments[$countIndex + 1] -ceq '200000') 'pilot override did not set finite /n'
$describedHost = & $runner -ClientPath 'missing-client.exe' -PeerPath 'missing-server.exe' -PeerPid 0 `
    -PeerArguments @('/p','tcp','/s','7000') -ExpectedPeerSha256 ('a' * 64) -Port 7000 `
    -Case 'tcp_128_k1' -OutputDirectory $nonexistentOutput -Label 'dry-run' -DescribeOnly -HostAddress '127.0.0.2'
Assert-True ($describedHost.arguments[0] -ceq '127.0.0.2') 'runner ignored explicit peer IPv4 address'
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('zig-client-provenance-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureDirectory
$fixtureExe = Join-Path $fixtureDirectory 'frozen-client.exe'
$marker = Join-Path $fixtureDirectory 'source-commit.txt'
try {
    $missingRejected = $false
    try { $null = Get-ExecutableCommit -Path $fixtureExe } catch { $missingRejected = $true }
    Assert-True $missingRejected 'missing executable source marker was accepted'
    Assert-True ($null -eq (Get-ExecutableCommit -Path $fixtureExe -AllowUnknown)) 'unknown peer commit was invented'
    $expectedCommit = '557cc03dab581347147b1b682076d4992c3137d0'
    Set-Content -LiteralPath $marker -Value $expectedCommit -Encoding ascii
    Assert-True ((Get-ExecutableCommit -Path $fixtureExe) -ceq $expectedCommit) 'frozen executable marker was ignored'
    Set-Content -LiteralPath $marker -Value 'invalid' -Encoding ascii
    $invalidRejected = $false
    try { $null = Get-ExecutableCommit -Path $fixtureExe } catch { $invalidRejected = $true }
    Assert-True $invalidRejected 'malformed executable source marker was accepted'
} finally {
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
    Remove-Item -LiteralPath $fixtureDirectory
}

Write-Output 'client performance runner contract passed'
