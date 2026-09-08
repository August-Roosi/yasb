<#
    meters.ps1 - drives the proportional fill behind the volume and battery cells.

    Qt paints a widget's background from the stylesheet, so a fill whose width
    tracks a live value has to arrive as CSS. yasb cannot compute one: a rule can
    only key off the classes a widget sets, and those are coarse (battery has five
    thresholds) or absent entirely (volume exposes only "muted"). So this script
    polls both values and writes meters.css - a hard-stop horizontal gradient per
    cell, with the stop at the current percentage. yasb's stylesheet watcher picks
    the file up and restyles.

    The same shape as vpn_status.ps1: generated, gitignored, imported last, and
    rewritten only when the value actually changes so an idle machine costs
    nothing. Colours are var() tokens rather than literals, so the fills follow
    the VPN light switch like everything else.

    Prints nothing. The widget that runs it is hidden by hide_empty.
#>

$ErrorActionPreference = 'Stop'

$CssFile = Join-Path $PSScriptRoot 'meters.css'
$InteropDll = Join-Path $PSScriptRoot '.native_interop.dll'

# Rounding to whole percent is finer than the cell can show (a 60px cell moves
# by half a pixel per step) and keeps the file from being rewritten on jitter.
function Get-Quantized([double]$Value) {
    [int][math]::Round($Value)
}

# Volume needs CoreAudio and battery needs GetSystemPowerStatus; both live in one
# assembly that is compiled once and cached, because Add-Type from source on
# every poll would cost more than everything else here put together.
function Initialize-Interop {
    if (Test-Path -LiteralPath $InteropDll) {
        Add-Type -Path $InteropDll
        return
    }

    $source = @'
using System;
using System.Runtime.InteropServices;

public static class SystemMeters
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumerator { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out int channelCount);
        int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);
        int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        int GetMasterVolumeLevel(out float levelDb);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid eventContext);
        int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
        int GetChannelVolumeLevel(uint channel, out float levelDb);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid eventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    // Negative means "no reading" - the caller leaves the previous fill alone
    // rather than flashing an empty cell when an endpoint is briefly missing.
    public static int VolumePercent()
    {
        try
        {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDevice device;
            if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0) { return -1; }
            object raw;
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            if (device.Activate(ref iid, 23, IntPtr.Zero, out raw) != 0) { return -1; }
            var volume = (IAudioEndpointVolume)raw;
            bool muted;
            if (volume.GetMute(out muted) == 0 && muted) { return 0; }
            float level;
            if (volume.GetMasterVolumeLevelScalar(out level) != 0) { return -1; }
            return (int)Math.Round(level * 100);
        }
        catch { return -1; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    public static int BatteryPercent()
    {
        SYSTEM_POWER_STATUS status;
        if (!GetSystemPowerStatus(out status)) { return -1; }
        if (status.BatteryLifePercent == 255) { return -1; }
        return status.BatteryLifePercent;
    }
}
'@

    Add-Type -TypeDefinition $source -OutputAssembly $InteropDll -OutputType Library
    Add-Type -Path $InteropDll
}

# One cell's rule. The two stops sit a thousandth apart so the transition is a
# hard cutoff rather than a wash, and the degenerate ends are emitted as a flat
# colour because a gradient stop cannot sit outside 0..1.
function Format-Rule([string]$Selector, [int]$Percent, [string]$FillToken) {
    $fill = "var(--$FillToken)"
    $rest = 'var(--status-bar-bg)'
    if ($Percent -le 0) {
        $paint = $rest
    }
    elseif ($Percent -ge 100) {
        $paint = $fill
    }
    else {
        $stop = ($Percent / 100.0).ToString('0.000', [cultureinfo]::InvariantCulture)
        $next = (($Percent / 100.0) + 0.001).ToString('0.000', [cultureinfo]::InvariantCulture)
        $paint = "qlineargradient(x1:0, y1:0, x2:1, y2:0, " +
                 "stop:$stop $fill, stop:$next $rest)"
    }
    ".yasb-bar $Selector {`n    background-color: $paint;`n}"
}

try {
    Initialize-Interop

    $volume = [SystemMeters]::VolumePercent()
    $battery = [SystemMeters]::BatteryPercent()

    $rules = @()
    if ($volume -ge 0) {
        $rules += Format-Rule '.volume-widget' (Get-Quantized $volume) 'status-volume-fill'
    }
    if ($battery -ge 0) {
        # Below the "low" threshold the fill turns into the bar's alarm colour,
        # so a nearly flat battery is loud without needing a second element.
        $token = if ($battery -le 20) { 'status-battery-alarm' } else { 'status-battery-fill' }
        $rules += Format-Rule '.battery-widget' (Get-Quantized $battery) $token
    }
    if ($rules.Count -eq 0) { return }

    $desired = "/* Generated by meters.ps1 - do not edit. */`n" +
               "/* volume: $volume  battery: $battery */`n" +
               ($rules -join "`n") + "`n"

    $current = ''
    if (Test-Path -LiteralPath $CssFile) {
        $current = [System.IO.File]::ReadAllText($CssFile)
    }
    if ($current -ne $desired) {
        # BOM-less UTF-8, like every other stylesheet here.
        [System.IO.File]::WriteAllText($CssFile, $desired, [System.Text.UTF8Encoding]::new($false))
    }
}
catch {
    # A failed poll must never take the bar's styling with it: leave whatever
    # meters.css already says in place and try again on the next interval.
}
