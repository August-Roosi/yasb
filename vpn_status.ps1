<#
    vpn_status.ps1 - drives the yasb "vpn_status" custom widget.

    Two jobs:
      1. Print the name of the VPN network(s) currently in use, or nothing at all
         when none are. yasb's hide_empty then hides the widget.
      2. Switch the bar to the light palette whenever a *real* VPN tunnel is up,
         by rewriting theme.css. yasb's stylesheet watcher picks that up and
         hot-reloads.

    Only a "real tunnel" (Fortinet, WireGuard, OpenVPN, AnyConnect, ...) counts.
    Mesh overlays (Tailscale, ZeroTier, ...) are deliberately ignored - they tend
    to be up permanently, so they are noise here. They still have to be matched
    explicitly, though, so they are not mistaken for WireGuard: both use Wintun.

    Detection requires an adapter that is Up *and* carries a routable IPv4.
    Matching on the adapter name alone is not enough: SSL-VPN virtual adapters
    commonly stay "Up" while disconnected, and they only get a tunnel address
    once the tunnel is actually established.

    Naming prefers the actual network over the vendor - "TEHIK", not "Fortinet".
    See Get-FortinetTunnelName for how the live tunnel is identified.
#>

$ErrorActionPreference = 'Stop'

$CacheFile = Join-Path $PSScriptRoot '.vpn_cache.json'

# Matched only so these are excluded from $VpnPatterns below - never reported.
$MeshPatterns = @(
    @{ Pattern = 'Tailscale';              Name = 'Tailscale' }
    @{ Pattern = 'ZeroTier';               Name = 'ZeroTier' }
    @{ Pattern = 'NetBird';                Name = 'NetBird' }
    @{ Pattern = 'Twingate';               Name = 'Twingate' }
    @{ Pattern = 'Nebula';                 Name = 'Nebula' }
)

$VpnPatterns = @(
    @{ Pattern = 'FortiClient|Fortinet';   Name = 'Fortinet' }
    @{ Pattern = 'NordLynx|NordVPN';       Name = 'NordVPN' }
    @{ Pattern = 'Proton';                 Name = 'ProtonVPN' }
    @{ Pattern = 'Mullvad';                Name = 'Mullvad' }
    @{ Pattern = 'ExpressVPN';             Name = 'ExpressVPN' }
    @{ Pattern = 'Surfshark';              Name = 'Surfshark' }
    @{ Pattern = 'AnyConnect';             Name = 'AnyConnect' }
    @{ Pattern = 'GlobalProtect|PANGP';    Name = 'GlobalProtect' }
    @{ Pattern = 'SonicWall|NetExtender';  Name = 'SonicWall' }
    @{ Pattern = 'Check ?Point';           Name = 'Check Point' }
    @{ Pattern = 'Pulse Secure|Ivanti';    Name = 'Pulse Secure' }
    @{ Pattern = 'Juniper';                Name = 'Juniper' }
    @{ Pattern = 'SoftEther';              Name = 'SoftEther' }
    @{ Pattern = 'ZScaler';                Name = 'ZScaler' }
    @{ Pattern = 'Netskope';               Name = 'Netskope' }
    @{ Pattern = 'OpenConnect';            Name = 'OpenConnect' }
    @{ Pattern = 'OpenVPN|TAP-Windows';    Name = 'OpenVPN' }
    @{ Pattern = 'WireGuard|Wintun';       Name = 'WireGuard' }   # after Tailscale: it also uses Wintun
)

function Get-MatchedName {
    param([string]$Text, [array]$Table)
    foreach ($entry in $Table) {
        if ($Text -match $entry.Pattern) { return $entry.Name }
    }
    return $null
}

function Format-NetworkName {
    # "TEHIK-VPN" -> "TEHIK", "TRAM VPN" -> "TRAM". Keeps the organisation, drops
    # the redundant suffix - the badge icon already says it is a VPN.
    param([string]$Name)
    $n = $Name -replace '\s*[-_ ]?VPN$', ''
    if ([string]::IsNullOrWhiteSpace($n)) { return $Name }
    return $n.Trim()
}

function Get-FortinetTunnelName {
    <#
        FortiClient's registry lists every *configured* tunnel, not the live one,
        so the name alone is not enough. The SSL-VPN daemon holds an established
        TCP connection to the gateway it is actually attached to, so match that
        connection's remote address against each configured tunnel's server.

        Resolving those hostnames on every 5s poll would be wasteful and would
        fail offline, so the remote-IP -> tunnel-name mapping is cached on disk
        and DNS is only consulted on a cache miss (i.e. when the gateway changes).
    #>
    # Live sockets, straight from .NET: ~50ms, versus ~500ms for
    # Get-NetTCPConnection plus its module load. No PID needed - matching the
    # remote endpoint against the configured gateways is enough to identify it.
    $endpoints = @{}
    try {
        foreach ($c in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections()) {
            if ($c.State -ne 'Established') { continue }
            $endpoints["$($c.RemoteEndPoint.Address.IPAddressToString):$($c.RemoteEndPoint.Port)"] = $true
        }
    } catch { return $null }
    if ($endpoints.Count -eq 0) { return $null }

    # Fast path: gateway endpoint already known.
    $cache = @{}
    if (Test-Path $CacheFile) {
        try {
            (Get-Content $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $cache[$_.Name] = $_.Value }
            foreach ($ep in $cache.Keys) {
                if ($endpoints.ContainsKey($ep)) { return $cache[$ep] }
            }
        } catch { $cache = @{} }
    }

    # Slow path: enumerate configured tunnels, resolve their gateways, match.
    # Only reached while a Fortinet tunnel adapter is actually up, so this runs
    # once per new gateway rather than on every poll.
    $resolved = $null
    foreach ($root in @('HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels',
                        'HKLM:\SOFTWARE\WOW6432Node\Fortinet\FortiClient\Sslvpn\Tunnels',
                        'HKCU:\Software\Fortinet\FortiClient\Sslvpn\Tunnels')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $server = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).Server
            if (-not $server) { continue }
            $parts = $server -split ':'
            $gwHost = $parts[0]
            $gwPort = if ($parts.Count -gt 1) { $parts[1] } else { '443' }
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($gwHost) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    ForEach-Object { $_.IPAddressToString }
            } catch { continue }
            foreach ($ip in $ips) {
                $ep = "${ip}:${gwPort}"
                if ($endpoints.ContainsKey($ep)) {
                    $resolved = $key.PSChildName
                    $cache[$ep] = $resolved
                    break
                }
            }
            if ($resolved) { break }
        }
        if ($resolved) { break }
    }

    if ($resolved) {
        try { ($cache | ConvertTo-Json -Compress) | Set-Content $CacheFile -Encoding UTF8 -NoNewline } catch { }
    }
    return $resolved
}

$vpnNames = [System.Collections.Generic.List[string]]::new()

try {
    # .NET gives status, description and addresses in one pass for ~95ms; the
    # equivalent Get-NetAdapter + Get-NetIPAddress pair costs ~1.5s per poll.
    $sawPpp = $false
    $adapters = foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Ppp') { $sawPpp = $true }
        $routable = $false
        try {
            foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
                if ($ua.Address.IPAddressToString -notmatch '^(169\.254\.|127\.)') { $routable = $true }
            }
        } catch { }
        if (-not $routable) { continue }
        [pscustomobject]@{ Name = $nic.Name; Description = $nic.Description }
    }

    foreach ($adapter in $adapters) {
        $text = "$($adapter.Description) $($adapter.Name)"

        if (Get-MatchedName -Text $text -Table $MeshPatterns) { continue }

        $vendor = Get-MatchedName -Text $text -Table $VpnPatterns
        if (-not $vendor) { continue }

        # Prefer the real network name over the vendor label.
        $name = $null
        if ($vendor -eq 'Fortinet') {
            $tunnel = Get-FortinetTunnelName
            if ($tunnel) { $name = Format-NetworkName $tunnel }
        } elseif ($vendor -eq 'WireGuard') {
            # WireGuard names the adapter after the tunnel config.
            if ($adapter.Name -notmatch '^(Ethernet|Local Area Connection)') {
                $name = Format-NetworkName $adapter.Name
            }
        }
        if (-not $name) { $name = $vendor }

        if (-not $vpnNames.Contains($name)) { $vpnNames.Add($name) }
    }

    # Built-in Windows VPN profiles (PPTP/L2TP/IKEv2/SSTP) already report a real
    # profile name, which beats any vendor label. Those connect over a PPP
    # interface, so skip the ~570ms lookup entirely when no PPP link is up.
    foreach ($scope in @($false, $true)) {
        if (-not $sawPpp) { break }
        try {
            $conns = if ($scope) {
                Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue
            } else {
                Get-VpnConnection -ErrorAction SilentlyContinue
            }
            foreach ($c in ($conns | Where-Object { $_.ConnectionStatus -eq 'Connected' })) {
                $n = Format-NetworkName $c.Name
                if ($n -and -not $vpnNames.Contains($n)) { $vpnNames.Add($n) }
            }
        } catch { }
    }
} catch {
    # Detection failed - report nothing and leave the theme untouched.
    Write-Output ''
    exit 0
}

$onVpn = $vpnNames.Count -gt 0

# ---- theme switch -------------------------------------------------------
# Rewrite theme.css only when the state actually changes, so the 5s poll does
# not trigger a stylesheet reload on every tick.
try {
    $themeFile = Join-Path $PSScriptRoot 'theme.css'
    $state     = if ($onVpn) { 'vpn' } else { 'no-vpn' }
    $body      = if ($onVpn) { "@import `"css/theme-light.css`";`n" } else { '' }
    $desired   = "/* Generated by vpn_status.ps1 - do not edit. */`n/* state: $state */`n$body"

    $current = ''
    if (Test-Path $themeFile) { $current = Get-Content $themeFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue }
    if ($null -eq $current) { $current = '' }

    if ($current -ne $desired) {
        # Write to a sibling temp file and rename over the target. yasb watches
        # this directory and reads theme.css the moment it changes; writing in
        # place lets it open a half-written (or still-locked) file, which shows
        # up as "CSSProcessor Error ... Permission denied" and silently drops the
        # palette for that reload. A rename is atomic, so the watcher only ever
        # sees a complete file. The .tmp name is not an imported stylesheet, so
        # creating it does not itself trigger a reload.
        # UTF8Encoding($false) rather than Set-Content -Encoding utf8: PS 5.1
        # always emits a BOM, and yasb reads stylesheets as plain utf-8, so the
        # BOM survives as a stray ﻿ at the head of the sheet.
        $tmp = "$themeFile.tmp"
        [System.IO.File]::WriteAllText($tmp, $desired, (New-Object System.Text.UTF8Encoding $false))
        Move-Item -Path $tmp -Destination $themeFile -Force
    }
} catch {
    # A theme write failure must not take the label down with it.
}

# ---- label --------------------------------------------------------------
if ($vpnNames.Count -eq 0) {
    Write-Output ''
} else {
    Write-Output ($vpnNames -join ' + ')
}
