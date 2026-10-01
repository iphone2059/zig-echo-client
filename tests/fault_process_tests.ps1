param(
    [string]$DriverPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-client-fault-driver.exe')
)

$ErrorActionPreference = 'Stop'
$driver = (Resolve-Path -LiteralPath $DriverPath).Path
$expected = @{
    notify_failure = 'RIONotify(client)'
    corrupt_cq = 'RIODequeueCompletion(client)'
    invalid_transition = 'client notification delivery transition'
    control_post_failure = 'PostQueuedCompletionStatus(client stop)'
    outstanding_release = 'client worker release precondition'
}
foreach ($mode in @('notify_failure', 'corrupt_cq', 'invalid_transition', 'control_post_failure', 'outstanding_release')) {
    $id = [Guid]::NewGuid().ToString('N')
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "zig-client-fault-$id-out.txt"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "zig-client-fault-$id-err.txt"
    $process = $null
    try {
        $process = Start-Process -FilePath $driver -ArgumentList $mode -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force
            throw "$mode did not terminate"
        }
        $out = Get-Content -LiteralPath $stdout -Raw
        $err = Get-Content -LiteralPath $stderr -Raw
        if ($process.ExitCode -ne 4 -or $out.Length -ne 0 -or -not $err.Contains($expected[$mode])) {
            throw "${mode}: exit=$($process.ExitCode), stdout=$out, stderr=$err"
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdout, $stderr -ErrorAction SilentlyContinue
    }
}
Write-Output 'client fault process tests passed'
