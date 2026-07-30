# Enforce "Keep printed documents" = OFF on every printer, so a printed
# receipt/ticket is NEVER retained in the Windows print queue where it could be
# re-printed later and a winning-but-unclaimed ticket cashed by someone. With this
# OFF, Windows deletes each job the instant it finishes printing — nothing
# reprintable is left behind. The once-a-day spool clear (CleanPrintSpool.bat) is
# the backstop that also clears STUCK/errored jobs, which can linger even when
# Keep is off.
#
# Always runs as SYSTEM (changing printer config needs "Manage this printer", which a
# standard "banca" user does NOT have — so the cashier can't turn retention back on
# either), from THREE callers:
#   1. InstallWatcher.bat at install, with -Baseline (see the switch below).
#   2. The "WinConfig Cleanup At Logon" task, every logon.
#   3. The "WinConfig Sync" poll task (poll-hub.js), ~hourly. This one is what makes
#      the guard actually continuous: a banca is routinely left ON for DAYS —
#      hibernated, or just locked, never intentionally shut down — and an onlogon
#      trigger does NOT fire on resume-from-hibernate or on unlock (Windows restores
#      the session, it doesn't create one). Caller 2 alone can therefore go a week
#      without running while Keep=ON sits there. See docs/plans/0010.
# Best-effort + idempotent: it never throws, never blocks anything, and only writes to
# the log when it actually changes something.
#
# GOLDEN-RULE NOTE: orthogonal to filtering. It NEVER reads or writes
# ProxyEnable/ProxyServer, never starts/stops the proxy, never touches routing — safe
# to run in any state (filtering, unplugged, mid-update). Sibling: HardenPower.ps1.

# -Baseline = "this is the install-time first pass, not a guard hit". At install a
# printer may legitimately arrive with Keep=ON from its driver default, so correcting
# it is expected housekeeping and gets logged as informational. EVERY LATER run means
# something flipped it back ON after we'd already turned it OFF, which is a
# ticket-retention (theft) signal and gets logged as `tamper` so poll-hub.js forwards
# it to the fleet's red alert. Keeping install out of that channel is deliberate: a
# false "intentó retener tickets" on every fresh install would train Nelson to ignore
# the alert.
param([switch]$Baseline)

$ErrorActionPreference = 'SilentlyContinue'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EventsPath = Join-Path $BrainDir 'events.log'

function Write-Event([string]$tag, [string]$detail) {
    try {
        $suffix = if ($detail) { " | $detail" } else { "" }
        $line = "[{0}] {1}{2}" -f (Get-Date).ToUniversalTime().ToString('o'), $tag, $suffix
        Add-Content -Path $EventsPath -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

# Get-Printer / Set-Printer are the PrintManagement module (Windows 8+/10/11) —
# always present on the real terminals. If unavailable (some minimal image), skip
# quietly rather than error.
if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
    Write-Event 'printer-guard-skip' 'PrintManagement no disponible'
    exit 0
}

$changed = @()
try {
    foreach ($p in (Get-Printer -ErrorAction SilentlyContinue)) {
        if (-not $p.KeepPrintedJobs) { continue }   # already off — nothing to do
        try {
            Set-Printer -Name $p.Name -KeepPrintedJobs $false -ErrorAction Stop
            $changed += $p.Name
        } catch {
            # Fallback: clear the 0x2000 ("Keep Printed Jobs") attribute bit via WMI.
            try {
                $safe = $p.Name -replace "'", "''"
                $wmi = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f $safe) -ErrorAction Stop
                if ($wmi -and ($wmi.Attributes -band 0x2000)) {
                    $wmi | Set-CimInstance -Property @{ Attributes = ($wmi.Attributes -band (-bnot 0x2000)) } -ErrorAction Stop
                    $changed += ($p.Name + ' (wmi)')
                }
            } catch {}
        }
    }
} catch {}

if ($changed.Count -gt 0) {
    $list = $changed -join ', '
    if ($Baseline) {
        Write-Event 'printer-keep-off' ("estado inicial corregido (Keep=OFF) en: $list")
    } else {
        # `tamper` is the tag poll-hub.js lifts into tamper_events (cross-repo contract)
        # → fleet red alert. Detail is written for a human reading that alert.
        Write-Event 'tamper' ("intento de retener tickets: Keep=ON revertido en $list")
    }
}
exit 0
