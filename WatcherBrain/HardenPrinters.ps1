# Enforce "Keep printed documents" = OFF on every printer, so a printed
# receipt/ticket is NEVER retained in the Windows print queue where it could be
# re-printed later and a winning-but-unclaimed ticket cashed by someone. With this
# OFF, Windows deletes each job the instant it finishes printing — nothing
# reprintable is left behind. This is the CONTINUOUS guard; the once-a-day spool
# clear (CleanPrintSpool.bat) is the backstop that also clears STUCK/errored jobs,
# which can linger even when Keep is off.
#
# Runs as SYSTEM — from InstallWatcher at install and from the logon cleanup task
# every logon. That matters: changing printer config needs "Manage this printer"
# rights, which a standard "banca" user does NOT have (so the cashier can't turn
# retention back on either). Best-effort + idempotent: it never throws, never
# blocks anything, and only writes to the log when it actually changes something.
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
    Write-Event 'printer-keep-off' ('forzado Keep=OFF en: ' + ($changed -join ', '))
}
exit 0
