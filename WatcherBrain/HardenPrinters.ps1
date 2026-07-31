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

# ---------------------------------------------------------------------------
# PRINT LOG (plan 0013). Windows records every printed document as event 307 in
# Microsoft-Windows-PrintService/Operational — printer, document, pages, time.
# That channel ships DISABLED by default, which is why it held nothing. This block
# turns it on and re-asserts it; poll-hub.js harvests the 307s and owns the cursor.
#
# It sits ABOVE the PrintManagement gate on purpose: poll-hub.js runs this whole
# script under ONE 25s spawnSync budget, and Get-Printer can hang for seconds against
# a dead network printer or a sick spooler. Below the gate, such a machine would time
# out (.status null => veto) and — since the throttle marker is stamped BEFORE the run —
# not retry for ~55 min, so the log would never get enabled there at all.
#
# The Keep=OFF loop below is untouched by this block; the only thing the gate gains is
# an exit with the precedence written down: 2 (failed) > 3 (could not evaluate) > 0.
$PrintLogChannel  = 'Microsoft-Windows-PrintService/Operational'
$PrintLogFlagPath = Join-Path $BrainDir 'print-log-baselined.flag'
$logFailed  = $false   # tried and could NOT verify => exit 2
$logSkipped = $false   # could not evaluate at all  => exit 3

# Per-machine marker, same shape and same REASON as hibernate-baselined.flag (plan 0012):
# poll-hub.js invokes this script WITHOUT -Baseline, so -Baseline cannot separate "the
# debut on an already-installed machine" from "someone turned it off". The MARKER can,
# because the OTA'd machines that need the distinction are exactly the ones that never
# see -Baseline. Gitignored + kept out of the bundle: a fresh install must NOT arrive
# pre-baselined, or it would swallow the first real revert as housekeeping.
# -PathType Leaf is deliberate — a directory of that name is not a valid marker.
function Set-PrintLogBaseline {
    try {
        if (-not (Test-Path $PrintLogFlagPath -PathType Leaf)) {
            Set-Content -Path $PrintLogFlagPath -Value ((Get-Date).ToUniversalTime().ToString('o')) -ErrorAction Stop
        }
        return (Test-Path $PrintLogFlagPath -PathType Leaf)
    } catch { return $false }
}

# Reads the channel through wevtutil (a native binary, ~10-30ms) rather than
# `Get-WinEvent -ListLog`, which loads the Diagnostics module and talks to the EventLog service
# with no timeout of its own. That difference is not cosmetic HERE: this block runs BEFORE the
# Keep=OFF loop, inside poll-hub.js's single 25s spawnSync budget for the whole script, so a
# stuck EventLog service would starve the ticket-retention guard that is this file's reason to
# exist. Returns $true / $false, or $null when the state could not be read at all.
function Get-PrintLogEnabled {
    try {
        $out = & wevtutil.exe gl $PrintLogChannel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        foreach ($line in $out) {
            if ($line -match '^\s*enabled:\s*(true|false)\s*$') { return ($Matches[1] -eq 'true') }
        }
        return $null
    } catch { return $null }
}

# UNREADABLE IS NOT DISABLED. With $ErrorActionPreference='SilentlyContinue' a failed
# read yields $null, and $null.IsEnabled reads as "off" — which would fabricate a tamper
# and paint a healthy machine red. Same split as HardenPower.ps1: a previous state we
# actually READ can accuse; an unknown one never can.
$logEnabled = Get-PrintLogEnabled

$logBaselined = Test-Path $PrintLogFlagPath -PathType Leaf

if ($null -eq $logEnabled) {
    Write-Event 'print-log-skip' "no se pudo leer el estado de $PrintLogChannel"
    $logSkipped = $true
} elseif ($logEnabled) {
    # Already on. Still claim the baseline, so a LATER disable is attributable to someone.
    # (An OEM image or an admin may have got there first — that is not a tamper.)
    if (-not $logBaselined -and -not (Set-PrintLogBaseline)) {
        Write-Event 'print-log-enable-failed' 'no se pudo escribir el marcador de baseline'
        $logFailed = $true
    }
} else {
    # OFF. Enable, then VERIFY by RE-READING — wevtutil's exit code is not evidence.
    & wevtutil.exe sl $PrintLogChannel /e:true 2>$null | Out-Null
    $logAfter = Get-PrintLogEnabled

    if ($logAfter -eq $true) {
        # `-not $Baseline` for the same reason the Keep=OFF loop below has it: a REINSTALL IN PLACE
        # keeps the directory (InstallWatcher.bat uses %~dp0) and therefore the marker, so without
        # this an install with the log off would raise a red "manipulación" during the install
        # itself. A false alert on install is how you train Nelson to ignore the real ones.
        if ($logBaselined -and -not $Baseline) {
            # WE had already enabled it on THIS machine, so someone turned it off after us.
            # Turning this log off is the only way to print without leaving a trace — there is
            # no accidental cause, which is why the fleet treats setting=print-log as red.
            Write-Event 'tamper' ('setting=print-log | registro de impresion apagado; reactivado')
        } else {
            # DEBUT on a machine that receives this by OTA: enabling it is housekeeping, never
            # an accusation. See wiki/lessons/new-rule-in-a-deployed-detector-self-accuses.
            if (-not (Set-PrintLogBaseline)) {
                Write-Event 'print-log-enable-failed' 'no se pudo escribir el marcador de baseline'
                $logFailed = $true
            }
            # Two ways to land here, and the local log is the ONLY trace of which: a genuine debut,
            # or a revert absorbed by an in-place reinstall (already baselined, but -Baseline given).
            # Saying "primera vez" for the second would erase the only record that it had been off.
            $detail = if ($logBaselined) {
                'reactivado durante la instalacion; NO se reporta como manipulacion'
            } else {
                'registro de impresion habilitado (primera vez en esta maquina)'
            }
            Write-Event 'print-log-enabled' $detail
        }
    } else {
        # Names the culprit: with three guards feeding one machine-wide guards_checked_at,
        # a veto that does not say WHO vetoed leaves a machine "never confirmed" forever
        # (e.g. a GPO forbidding the channel) with nobody able to tell why.
        Write-Event 'print-log-enable-failed' "no se pudo habilitar $PrintLogChannel (verificado releyendo)"
        $logFailed = $true
    }
}
# ---------------------------------------------------------------------------

# Get-Printer / Set-Printer are the PrintManagement module (Windows 8+/10/11) —
# always present on the real terminals. If unavailable (some minimal image), the
# setting simply cannot be evaluated on this machine — SKIP / N-A, not a pass.
if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
    Write-Event 'printer-guard-skip' 'PrintManagement no disponible'
    if ($logFailed) { exit 2 }
    exit 3
}

# Exit-code contract (poll-hub.js reads this): 0 = VERIFIED-CLEAN (read+enforced, or
# already correct — an empty printer loop counts as clean), 2 = HARDEN-FAILED (tried to
# set but the re-check shows it did NOT take), 3 = SKIP/N-A (could not evaluate at all).
$changed = @()   # printers this run actually FLIPPED (verified) -> 'printer-keep-off'/'tamper'
$failed  = @()   # printers we TRIED to fix but neither Set-Printer nor the WMI fallback took
$evalFailed = $false
try {
    # TERMINATING enumeration (cross-review): a real Get-Printer failure must THROW → caught below →
    # exit 3 (could not evaluate), NEVER a silent empty list that would false-report "verified clean".
    $printers = Get-Printer -ErrorAction Stop
    foreach ($p in $printers) {
        if (-not $p.KeepPrintedJobs) { continue }   # already off — nothing to do
        # Try Set-Printer, then the WMI 0x2000-bit fallback. We do NOT trust either succeeded —
        # the re-read below is the sole source of truth for whether it actually took.
        try {
            Set-Printer -Name $p.Name -KeepPrintedJobs $false -ErrorAction Stop
        } catch {
            try {
                $safe = $p.Name -replace "'", "''"
                $wmi = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f $safe) -ErrorAction Stop
                if ($wmi -and ($wmi.Attributes -band 0x2000)) {
                    $wmi | Set-CimInstance -Property @{ Attributes = ($wmi.Attributes -band (-bnot 0x2000)) } -ErrorAction Stop
                }
            } catch {}
        }
        # VERIFY by re-reading the FINAL state — exit 0 must mean actually-OFF, not "we issued a Set".
        # Still ON, or unreadable, => this printer did NOT take => $failed (=> exit 2), never a false clean.
        $after = $null
        try { $after = (Get-Printer -Name $p.Name -ErrorAction Stop).KeepPrintedJobs } catch { $after = $null }
        if ($after -eq $false) {
            $changed += $p.Name          # confirmed flipped OFF by the re-read
        } else {
            $failed += $p.Name           # re-read shows still-ON (or unreadable) — did NOT take
        }
    }
} catch {
    # Couldn't even enumerate printers — the setting could not be evaluated this run.
    $evalFailed = $true
}

# Precedence, written down (plan 0013): 2 > 3 > 0. A machine that could not evaluate the
# Keep loop but DID fail to secure the print log must still report the failure, not a skip.
if ($evalFailed) {
    if ($logFailed) { exit 2 }
    exit 3
}

if ($changed.Count -gt 0) {
    $list = $changed -join ', '
    if ($Baseline) {
        Write-Event 'printer-keep-off' ("estado inicial corregido (Keep=OFF) en: $list")
    } else {
        # `tamper` is the tag poll-hub.js lifts into tamper_events (cross-repo contract)
        # → fleet red alert. `setting=printer-keep` is the dimension the fleet groups on.
        # Detail is written for a human reading that alert.
        Write-Event 'tamper' ("setting=printer-keep | intento de retener tickets: Keep=ON revertido en $list")
    }
}

if ($failed.Count -gt 0) {
    if (-not $Baseline) {
        # A printer we could NOT turn OFF is an ACTIVE ticket-retention exposure — the fleet must not
        # keep showing OK while Keep stays ON (cross-review A-re1). Emit a tamper (setting=printer-keep)
        # so it surfaces AND counts on the frequency ladder: a printer that never yields climbs to red,
        # which is correct. Distinct detail ("NO se pudo revertir") so a human tells it apart from a
        # revert-we-fixed. Still exit 2 (vetoes the guards-ok confirm — this machine is NOT clean).
        Write-Event 'tamper' ("setting=printer-keep | NO se pudo revertir, Keep sigue ON en: " + ($failed -join ', '))
    } else {
        # Install-time failure: keep it off the tamper channel (like -Baseline everywhere), but log it
        # locally; the next hourly (non-baseline) run will surface it as a tamper if it persists.
        Write-Event 'printer-harden-failed' ('no se pudo revertir en install: ' + ($failed -join ', '))
    }
    exit 2
}

# Keep loop is clean here. The print-log block still gets the last word, in precedence order:
# a log we could not secure is a FAILED guard (2); one we could not even read is a SKIP (3).
# Either way guards-ok.txt is not stamped — an unevaluated guard is not a clean guard.
if ($logFailed)  { exit 2 }
if ($logSkipped) { exit 3 }

exit 0
