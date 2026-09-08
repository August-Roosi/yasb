param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex')]
    [string]$Provider
)

$ErrorActionPreference = 'Stop'
$cachePath = Join-Path $PSScriptRoot ".ai_usage_$Provider.cache.json"

# yasb decodes this script's stdout as UTF-8, but Windows PowerShell writes a
# redirected stream in the console's OEM codepage - the meter glyphs below would
# arrive as mojibake without this.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Built from code points rather than written literally: powershell.exe 5.1 reads
# a BOM-less .ps1 as ANSI, so a literal block glyph in the source would already
# be corrupt before it was ever printed.
#
# Two glyphs, two weights: the lower half block draws the thick session meter,
# the lower one-eighth block the hairline week meter underneath it. Both tile
# without gaps in JetBrains Mono, so a run of them is a solid bar.
$MeterCells = 10
$MeterThick = [string][char]0x2584   # lower half block
$MeterThin = [string][char]0x2581    # lower one eighth block
$Nbsp = [string][char]0x00A0

function Get-StatusPalette {
    # The bar's colours live in the token table in css/theme-*.css. A rich-text
    # meter is painted by Qt from the markup, not by the stylesheet, so the
    # values have to be read out of the same files rather than duplicated here -
    # otherwise the meter would keep the dark palette when a VPN tunnel flips
    # the rest of the bar to light.
    $palette = @{
        'status-claude' = '#f97770'; 'status-claude-dim' = '#bb6d67'
        'status-codex' = '#e5d937'; 'status-codex-dim' = '#aaa23f'
        'status-track' = '#2d2824'; 'status-ink' = '#f0ebdc'
        'status-muted' = '#a39d98'
    }
    try {
        $active = Join-Path $PSScriptRoot 'theme.css'
        $name = 'theme-dark.css'
        if ((Test-Path -LiteralPath $active) -and
            ((Get-Content -LiteralPath $active -Raw) -match 'theme-light')) {
            $name = 'theme-light.css'
        }
        $css = Get-Content -LiteralPath (Join-Path $PSScriptRoot "css\$name") -Raw
        foreach ($m in [regex]::Matches($css, '--(status-[a-z0-9-]+):\s*([^;]+);')) {
            $palette[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
        }
    }
    catch {}
    $palette
}

function Format-Bar($Percent, $Glyph, $FillColor, $TrackColor) {
    $filled = [math]::Round(($Percent / 100.0) * $MeterCells)
    # Any consumption at all should light the first cell; a full window should
    # never look like it still has room.
    if ($filled -lt 1 -and $Percent -gt 0) { $filled = 1 }
    if ($filled -gt $MeterCells) { $filled = $MeterCells }
    $bar = ""
    if ($filled -gt 0) { $bar += "<font color='$FillColor'>" + ($Glyph * $filled) + "</font>" }
    if ($filled -lt $MeterCells) {
        $bar += "<font color='$TrackColor'>" + ($Glyph * ($MeterCells - $filled)) + "</font>"
    }
    $bar
}

function Get-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Credential file not found"
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Format-Usage($ShortWindow, $LongWindow) {
    $short = [math]::Round([double]$ShortWindow)
    $long = [math]::Round([double]$LongWindow)
    $p = Get-StatusPalette
    if ($Provider -eq 'claude') { $fill = $p['status-claude']; $dim = $p['status-claude-dim'] }
    else { $fill = $p['status-codex']; $dim = $p['status-codex-dim'] }
    $track = $p['status-track']

    # Two stacked rows, as in the design guide: the session window on top in
    # full weight, the seven-day window below as a hairline. Figures are padded
    # to a fixed width so the two rows stay in column.
    $top = (Format-Bar $short $MeterThick $fill $track) +
        "$Nbsp<font color='$($p['status-ink'])'>" + ("{0,3}%" -f $short) + "</font>"
    $bottom = (Format-Bar $long $MeterThin $dim $track) +
        "$Nbsp<font color='$($p['status-muted'])'>" + ("{0,3}% wk" -f $long) + "</font>"
    "$top<br>$bottom"
}

function Format-Unavailable {
    $p = Get-StatusPalette
    $track = $p['status-track']
    (Format-Bar 0 $MeterThick $track $track) +
        "$Nbsp<font color='$($p['status-muted'])'>" + ("{0,3}" -f '--') + "%</font>"
}

function Get-UsageCache {
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }
    try {
        Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    }
    catch {
        $null
    }
}

function Save-UsageCache($ShortWindow, $LongWindow) {
    $cache = [pscustomobject]@{
        short_window = [double]$ShortWindow
        long_window = [double]$LongWindow
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($cachePath, $cache, [System.Text.UTF8Encoding]::new($false))
}

try {
    if ($Provider -eq 'claude') {
        $credentials = Get-JsonFile "$env:USERPROFILE\.claude\.credentials.json"
        $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers @{
            Authorization = "Bearer $($credentials.claudeAiOauth.accessToken)"
            'anthropic-beta' = 'oauth-2025-04-20'
            'User-Agent' = 'YASB usage indicator'
        } -TimeoutSec 15

        $shortWindow = $response.five_hour.utilization
        $longWindow = $response.seven_day.utilization
        try { Save-UsageCache $shortWindow $longWindow } catch {}
        Format-Usage $shortWindow $longWindow
    }
    else {
        $credentials = Get-JsonFile "$env:USERPROFILE\.codex\auth.json"
        $response = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers @{
            Authorization = "Bearer $($credentials.tokens.access_token)"
            'Chatgpt-Account-Id' = $credentials.tokens.account_id
            'User-Agent' = 'YASB usage indicator'
        } -TimeoutSec 15

        $shortWindow = $response.rate_limit.primary_window.used_percent
        $longWindow = $response.rate_limit.secondary_window.used_percent
        try { Save-UsageCache $shortWindow $longWindow } catch {}
        Format-Usage $shortWindow $longWindow
    }
}
catch {
    $cachedUsage = Get-UsageCache
    # A 429 can throttle the status endpoint itself; it does not prove that a
    # subscription window is full. Preserve the last verified values instead.
    if ($cachedUsage) {
        Format-Usage $cachedUsage.short_window $cachedUsage.long_window
    }
    else {
        # Keep the bar informative without revealing endpoint or credential details.
        Format-Unavailable
    }
}
