param(
    [Parameter(Mandatory = $true)][ValidateSet('tcp', 'udp')][string]$Protocol,
    [Parameter(Mandatory = $true)][int]$Port,
    [ValidateSet('echo', 'blackhole', 'close', 'fragment')][string]$Mode = 'echo',
    [Parameter(Mandatory = $true)][string]$ReadyPath
)

$ErrorActionPreference = 'Stop'
if ($Protocol -eq 'udp') {
    $peer = [System.Net.Sockets.UdpClient]::new($Port)
    try {
        $peer.Client.ReceiveBufferSize = 4 * 1024 * 1024
        [IO.File]::WriteAllText($ReadyPath, 'READY')
        while ($true) {
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $data = $peer.Receive([ref]$remote)
            if ($Mode -eq 'echo') { [void]$peer.Send($data, $data.Length, $remote) }
        }
    } finally { $peer.Dispose() }
} else {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start(512)
    try {
        [IO.File]::WriteAllText($ReadyPath, 'READY')
        while ($true) {
            $socket = $listener.AcceptSocket()
            try {
                $buffer = [byte[]]::new(65536)
                while (($length = $socket.Receive($buffer)) -gt 0) {
                    if ($Mode -eq 'close') { break }
                    if ($Mode -eq 'blackhole') { continue }
                    $offset = 0
                    while ($offset -lt $length) {
                        $remaining = $length - $offset
                        $chunk = if ($Mode -eq 'fragment') { [Math]::Max(1, [int]($remaining / 2)) } else { $remaining }
                        $offset += $socket.Send($buffer, $offset, $chunk, [System.Net.Sockets.SocketFlags]::None)
                        if ($Mode -eq 'fragment') { Start-Sleep -Milliseconds 1 }
                    }
                }
            } finally { $socket.Dispose() }
        }
    } finally { $listener.Stop() }
}
