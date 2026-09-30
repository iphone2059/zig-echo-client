$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project 'src'
$files = @(Get-ChildItem -LiteralPath $source -Filter '*.zig' -File)
if ($files.Count -lt 8) { throw 'client source inventory is unexpectedly small' }
if (Test-Path -LiteralPath (Join-Path $source 'udp.zig')) { throw 'obsolete single-worker UDP path remains' }
if (-not (Test-Path -LiteralPath (Join-Path $source 'engine.zig'))) { throw 'fixed-worker engine missing' }
foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match '(?i)\bstd\.(net|posix)\b|\bc\.(WSASend|WSARecv|send|recv|select|WSAPoll)\s*\(') {
        throw "ordinary payload I/O or fallback found in $($file.Name)"
    }
    if ($text -match '(?i)@import\s*\(\s*["''][^"'']*(\.\.|cpp-echo|zig-echo-server|shared)[^"'']*["'']\s*\)') {
        throw "cross-project import found in $($file.Name)"
    }
    if ($text -match '(?i)\b(ArrayList|AutoHashMap)\s*\(\s*(Session|Worker|Request)\s*\)') {
        throw "movable published context container found in $($file.Name)"
    }
}
Write-Output 'client source policy passed'
