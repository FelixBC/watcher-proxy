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
# always present on the real terminals. If unavailable (some minimal image), the
# setting simply cannot be evaluated on this machine — SKIP / N-A, not a pass.
if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
    Write-Event 'printer-guard-skip' 'PrintManagement no disponible'
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

if ($evalFailed) { exit 3 }

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

exit 0
