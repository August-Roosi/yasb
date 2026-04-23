$vpnActive = $false

try {
    $vpnConnections = Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.ConnectionStatus -eq "Connected" }
    $vpnActive = @($vpnConnections).Count -gt 0
} catch {
    # Ignore and fall back to adapter-based detection.
}

if (-not $vpnActive) {
    $vpnAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and
            (
                $_.InterfaceDescription -match "VPN|WireGuard|TAP|TUN|OpenVPN|Wintun|AnyConnect|Cisco" -or
                $_.Name -match "AnyConnect|VPN"
            )
        }

    $vpnActive = @($vpnAdapters).Count -gt 0
}

if ($vpnActive) {
    Write-Output "1"
} else {
    Write-Output ""
}
