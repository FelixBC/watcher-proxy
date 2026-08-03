# headless-install-test.ps1 — reproduces the WinConfig wizard's EXACT handoff to
# InstallWatcher.bat on a real Windows box, WITHOUT the interactive WinForms window
# (CI/SSH have no desktop). This is the "does it actually install?" test — the thing
# a physical-desktop QA cannot automate. It mirrors WinConfigWizard.ps1's Start-Action
# byte for byte: same ProcessStartInfo, same env-var identity handoff, same closed
# stdin, same "> log 2>&1" redirect, same log-file polling for [n/N] progress and
# HasExited — then asserts the machine ended up ARMED (the invariant the wizard's
# green "Todo listo" screen is supposed to mean).
#
# Exit 0 = install reported success AND the armed-state invariants hold.
# Exit 1 = the install failed, or reported success but left the machine un-armed.
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\WinConfig',
    [string] $MasterCode  = 'CI-MASTER-TEST-9421',
    [string] $BancaCode    = '022',
    [int]    $MaxWaitSec  = 300
)

$ErrorActionPreference = 'Continue'

function Section([string]$t) { Write-Host ""; Write-Host "===== $t =====" }

Section "Environment"
Write-Host ("node: {0}" -f (node --version 2>&1))
Write-Host ("whoami: {0}" -f (whoami))
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("elevated: {0}" -f $isAdmin)

$BatPath = Join-Path $InstallRoot 'InstallWatcher.bat'
$BrainDir = Join-Path $InstallRoot 'WatcherBrain'
if (-not (Test-Path $BatPath)) { Write-Host "FATAL: $BatPath missing"; exit 1 }

# ---- Replicate WinConfigWizard.ps1 Start-Action --------------------------------
Section "Running InstallWatcher.bat via the wizard's handoff (hidden, env-var identity)"
$logPath = Join-Path $env:TEMP ('winconfig-wiz-{0}.log' -f ([guid]::NewGuid().ToString('N')))

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = ('/c "{0}" > "{1}" 2>&1' -f $BatPath, $logPath)
$psi.WorkingDirectory = $InstallRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = 'Hidden'
$psi.RedirectStandardInput = $true
$psi.EnvironmentVariables['WATCHER_MASTER_CODE'] = $MasterCode
$psi.EnvironmentVariables['WATCHER_MACHINE_NAME'] = 'CI Caja 1'
$psi.EnvironmentVariables['WATCHER_MACHINE_ZONE'] = 'CI Zone'
$psi.EnvironmentVariables['WATCHER_MACHINE_CODE'] = $BancaCode

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
# Install mode: identity is in env, so send nothing — just close stdin so the .bat's
# `pause` calls hit EOF and return (exactly as the wizard does).
$proc.StandardInput.Close()

# ---- Poll like On-Tick: surface each [n/N] as it appears ----------------------
$deadline = (Get-Date).AddSeconds($MaxWaitSec)
$lastSeen = ''
while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 400
    if (Test-Path $logPath) {
        try {
            $fs = New-Object System.IO.FileStream($logPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        } catch { $txt = '' }
        $mm = [regex]::Matches($txt, '\[(\d+)/(\d+)\]')
        if ($mm.Count -gt 0) {
            $cur = $mm[$mm.Count-1].Value
            if ($cur -ne $lastSeen) { Write-Host ("  progress -> {0}" -f $cur); $lastSeen = $cur }
        }
    }
    if ((Get-Date) -gt $deadline) {
        Write-Host "TIMEOUT: install did not finish in $MaxWaitSec s — killing."
        try { $proc.Kill() } catch {}
        break
    }
}
try { $exit = $proc.ExitCode } catch { $exit = -999 }

Section "Full InstallWatcher.bat log"
if (Test-Path $logPath) { Get-Content $logPath -Raw } else { Write-Host "(no log captured)" }

Section "wizard-error.log (if any)"
$werr = Join-Path $BrainDir 'wizard-error.log'
if (Test-Path $werr) { Get-Content $werr -Raw } else { Write-Host "(none)" }
$rstat = Join-Path $BrainDir 'register-status.txt'
Write-Host ("register-status.txt: {0}" -f (if (Test-Path $rstat) { (Get-Content $rstat -Raw).Trim() } else { '(none)' }))

# ---- Assert the armed-state invariants ----------------------------------------
Section "Post-install invariants"
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail='') {
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1}{2}" -f $tag, $name, (if ($detail) { " — $detail" } else { '' }))
    if (-not $ok) { $script:fail++ }
}

Check "InstallWatcher.bat exit == 0" ($exit -eq 0) ("exit=$exit")

$hashFile = Join-Path $BrainDir 'uninstall-code.hash'
$hashOk = (Test-Path $hashFile) -and ((Get-Item $hashFile).Length -gt 0)
Check "uninstall-code.hash written (armed<=>uninstallable)" $hashOk

$codeFile = Join-Path $InstallRoot 'machine-code.txt'
Check "machine-code.txt written" ((Test-Path $codeFile))

$portFile = Join-Path $BrainDir 'proxy-port.txt'
Check "proxy-port.txt written" ((Test-Path $portFile))

foreach ($tn in @('WinConfig','WinConfig Sync')) {
    schtasks /query /tn $tn >$null 2>&1
    Check ("scheduled task '$tn' exists") ($LASTEXITCODE -eq 0)
}

# plaintext master code must NOT survive anywhere
$leak = Get-ChildItem -Path $InstallRoot -Recurse -Filter '*.plain' -ErrorAction SilentlyContinue
Check "no *.plain master-code residue" (($leak | Measure-Object).Count -eq 0)

Section "Result"
if ($fail -eq 0 -and $exit -eq 0) {
    Write-Host "OK — install completed and armed-state invariants hold."
    exit 0
} else {
    Write-Host ("NOT OK — $fail invariant(s) failed, exit=$exit.")
    exit 1
}
