$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project 'src'
# The client is exactly nine source files, mirroring the Rust client's nine modules one for one.
# The list is closed on purpose: adding a file is an architecture change, not a refactor.
$expected = @(
    'contract.zig',
    'engine.zig',
    'internal.zig',
    'main.zig',
    'metrics.zig',
    'native.zig',
    'payload.zig',
    'root.zig',
    'types.zig'
)
$files = @(Get-ChildItem -LiteralPath $source -Filter '*.zig' -File)
$actual = @($files | ForEach-Object { $_.Name } | Sort-Object)
$missing = @($expected | Where-Object { $actual -notcontains $_ })
$extra = @($actual | Where-Object { $expected -notcontains $_ })
if ($missing.Count -ne 0) { throw "client source inventory is missing: $($missing -join ', ')" }
if ($extra.Count -ne 0) { throw "client source inventory has unexpected files: $($extra -join ', ')" }
if (-not (Test-Path -LiteralPath (Join-Path $source 'main.zig'))) { throw 'client entry point must be main.zig' }
if (Test-Path -LiteralPath (Join-Path $source 'udp.zig')) { throw 'obsolete single-worker UDP path remains' }
foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match '(?i)\bstd\.(net|posix)\b|\bc\.(WSASend|WSARecv|send|recv|select|WSAPoll)\s*\(') {
        throw "ordinary payload I/O or fallback found in $($file.Name)"
    }
    if ($text -match '(?i)@import\s*\(\s*["''][^"'']*(\.\.|cpp-echo|rust-echo|zig-echo-server|shared)[^"'']*["'']\s*\)') {
        throw "cross-project import found in $($file.Name)"
    }
    if ($text -match '(?i)\b(ArrayList|AutoHashMap)\s*\(\s*(Session|Worker|Request)\s*\)') {
        throw "movable published context container found in $($file.Name)"
    }
    if ($text -match '(?i)\bstd\.Thread\.Mutex\b') {
        throw "unsupported blocking mutex found in $($file.Name)"
    }
}
# native.zig may not depend on a state machine: the dependency direction has to stay one-way.
$nativeText = Get-Content -LiteralPath (Join-Path $source 'native.zig') -Raw
if ($nativeText -match '@import\s*\(\s*"(internal|engine|metrics|contract)\.zig"\s*\)') {
    throw 'native.zig must not depend on a state machine'
}
Write-Output 'client source policy passed'
