# headless-install-test.ps1 - reproduces the WinConfig wizard's EXACT handoff to
# InstallWatcher.bat on a real Windows box, WITHOUT the interactive WinForms window
# (CI/SSH have no desktop). This is the "does it actually install?" test - the thing
# a physical-desktop QA cannot automate. It mirrors WinConfigWizard.ps1's Start-Action:
# same ProcessStartInfo, same env-var identity handoff, same closed stdin, same
# "> log 2>&1" redirect, same log-file polling for [n/N] and HasExited - then asserts
# the machine ended up ARMED (what the wizard's green "Todo listo" is supposed to mean).
#
# Exit 0 = install reported success AND the armed-state invariants hold.
# Exit 1 = the install failed, or reported success but left the machine un-armed.
#
# ASCII-only + Windows PowerShell 5.1 syntax on purpose: that is what runs on a banca.
[CmdletBinding()]
param(
    [string] $InstallRoot = 'C:\WinConfig',
    [string] $MasterCode  = 'CI-MASTER-TEST-9421',
    [string] $BancaCode   = '022',
    [int]    $MaxWaitSec  = 300
)

$ErrorActionPreference = 'Continue'
$script:fail = 0

function Section([string]$t) { Write-Host ""; Write-Host "===== $t =====" }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $tag = 'FAIL'; if ($ok) { $tag = 'PASS' }
    $line = "  [$tag] $name"
    if ($detail) { $line = "$line - $detail" }
    Write-Host $line
    if (-not $ok) { $script:fail++ }
}

Section "Environment"
Write-Host ("node: {0}" -f (node --version 2>&1))
Write-Host ("whoami: {0}" -f (whoami))
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("elevated: {0}" -f $isAdmin)

$BatPath  = Join-Path $InstallRoot 'InstallWatcher.bat'
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
# Install mode: identity is in env, so send nothing - just close stdin so the .bat's
# `pause` calls hit EOF and return (exactly as the wizard does).
$proc.StandardInput.Close()

# ---- Poll like On-Tick: surface each [n/N] as it appears ----------------------
$deadline = (Get-Date).AddSeconds($MaxWaitSec)
$lastSeen = ''
while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 400
    $txt = ''
    if (Test-Path $logPath) {
        try {
            $fs = New-Object System.IO.FileStream($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        } catch { $txt = '' }
    }
    if ($txt) {
        $mm = [regex]::Matches($txt, '\[(\d+)/(\d+)\]')
        if ($mm.Count -gt 0) {
            $cur = $mm[$mm.Count - 1].Value
            if ($cur -ne $lastSeen) { Write-Host ("  progress -> {0}" -f $cur); $lastSeen = $cur }
        }
    }
    if ((Get-Date) -gt $deadline) {
        Write-Host "TIMEOUT: install did not finish in $MaxWaitSec s - killing."
        try { $proc.Kill() } catch {}
        break
    }
}
$exit = -999
try { $exit = $proc.ExitCode } catch {}

Section "Full InstallWatcher.bat log"
if (Test-Path $logPath) { Get-Content $logPath -Raw } else { Write-Host "(no log captured)" }

Section "Side signals"
$werr = Join-Path $BrainDir 'wizard-error.log'
if (Test-Path $werr) { Write-Host "wizard-error.log:"; Get-Content $werr -Raw } else { Write-Host "wizard-error.log: (none)" }
$rstat = Join-Path $BrainDir 'register-status.txt'
$rval = '(none)'
if (Test-Path $rstat) { $rval = (Get-Content $rstat -Raw).Trim() }
Write-Host ("register-status.txt: {0}" -f $rval)

# ---- Assert the armed-state invariants ----------------------------------------
Section "Post-install invariants"
Check "InstallWatcher.bat exit == 0" ($exit -eq 0) "exit=$exit"

$hashFile = Join-Path $BrainDir 'uninstall-code.hash'
$hashOk = (Test-Path $hashFile)
if ($hashOk) { $hashOk = ((Get-Item $hashFile).Length -gt 0) }
Check "uninstall-code.hash written (armed<=>uninstallable)" $hashOk

Check "machine-code.txt written" (Test-Path (Join-Path $InstallRoot 'machine-code.txt'))
Check "proxy-port.txt written" (Test-Path (Join-Path $BrainDir 'proxy-port.txt'))

foreach ($tn in @('WinConfig', 'WinConfig Sync')) {
    cmd /c "schtasks /query /tn ""$tn"" >nul 2>&1"
    Check "scheduled task '$tn' exists" ($LASTEXITCODE -eq 0)
}

$leak = @(Get-ChildItem -Path $InstallRoot -Recurse -Filter '*.plain' -ErrorAction SilentlyContinue)
Check "no *.plain master-code residue" ($leak.Count -eq 0)

Section "Result"
if ($script:fail -eq 0 -and $exit -eq 0) {
    Write-Host "OK - install completed and armed-state invariants hold."
    exit 0
}
Write-Host ("NOT OK - {0} invariant(s) failed, exit={1}." -f $script:fail, $exit)
exit 1
