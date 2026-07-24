# WinConfigWizard.ps1 — WinForms "asistente" that wraps InstallWatcher.bat (install)
# or BackToNormal.bat (uninstall) WITHOUT changing either. It only: collects the
# fields, runs the .bat HIDDEN, maps its [n/N] output to a progress bar, and shows
# a result screen. The window is titled "WinConfig" (disguise). Same logic and the
# golden-rule order underneath are untouched (plan 0004).
#
# Secret handling: the master code is passed to the child process WITHOUT ever
# reaching a command line or disk:
#   - Install:   set as an environment variable (WATCHER_MASTER_CODE); AskIdentity's
#                unattended path reads it. stdin is closed so the .bat's `pause`
#                calls return immediately.
#   - Uninstall: written to the child's stdin PIPE in memory (RedirectStandardInput);
#                BackToNormal's `set /p WATCHER_UNINSTALL_CODE=` reads it. This is why
#                BackToNormal.bat needs ZERO edits.
# The .bat's stdout+stderr go to a temp log file that a UI-thread Timer polls for
# [n/N] progress — no background threads, no stream-read races.
#
# Fallback: if WinForms cannot load, we fall back to running the .bat in a normal
# visible console (its existing interactive flow), so an install/uninstall is never
# blocked by a UI problem.

[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall')]
    [string] $Mode = 'Install'
)

$ErrorActionPreference = 'Stop'
$BrainDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir  = Split-Path -Parent $BrainDir

# ---- Self-elevate (UAC), same as the console installer needs today ------------
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Elevated)) {
    try {
        $selfArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode $Mode"
        Start-Process -FilePath 'powershell.exe' -ArgumentList $selfArgs -Verb RunAs -WindowStyle Hidden | Out-Null
    } catch {
        # User declined UAC (or elevation failed) — nothing was changed.
    }
    return
}

# ---- Per-mode configuration ---------------------------------------------------
if ($Mode -eq 'Install') {
    $BatPath   = Join-Path $RootDir 'InstallWatcher.bat'
    $TotalDefault = 8
    $StepLabels = @(
        'Preparando componentes...',
        'Registrando inicio automatico...',
        'Configurando seguridad...',
        'Optimizando impresion...',
        'Iniciando servicio...',
        'Aplicando configuracion de red...',
        'Conectando con el panel...',
        'Finalizando...'
    )
    $FormTitle    = 'WinConfig'
    $Heading      = 'Configuracion de WinConfig'
    $Lede         = 'Completa los datos del equipo para dejarlo listo.'
    $ActionText   = 'Instalar'
    $ProgHeading  = 'Configurando...'
} else {
    $BatPath   = Join-Path $RootDir 'BackToNormal.bat'
    $TotalDefault = 5
    $StepLabels = @(
        'Restaurando configuracion de red...',
        'Deteniendo servicio...',
        'Quitando inicio automatico...',
        'Quitando tareas programadas...',
        'Finalizando...'
    )
    $FormTitle    = 'WinConfig'
    $Heading      = 'Restaurar WinConfig'
    $Lede         = 'Escribe el codigo maestro para restaurar el equipo a la normalidad.'
    $ActionText   = 'Restaurar'
    $ProgHeading  = 'Restaurando...'
}

# ---- Console fallback (used if WinForms cannot load) --------------------------
function Invoke-ConsoleFallback {
    # Run the .bat in a normal visible console (its existing interactive flow:
    # AskIdentity popups for install, the code prompt for uninstall).
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "{0}"' -f $BatPath) -Wait
    } catch { }
}

# ---- Load WinForms ------------------------------------------------------------
# Target is Windows 10/11: Windows PowerShell 5.1 + .NET Framework 4.x WinForms are
# in-box, so this renders on a real terminal with nothing to install. (The "InputBox
# might not render" worry was only the minimal Server VM used for QA.)
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # High-DPI: real terminals often run at 125-150% scaling. Mark the process
    # DPI-aware BEFORE any window exists so text is crisp, not blurry bitmap-scaling
    # (blurry reads as a fake/broken setup and defeats the disguise). Best-effort.
    try {
        Add-Type -Namespace WinConfigNative -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
        [void][WinConfigNative.Dpi]::SetProcessDPIAware()
    } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }
} catch {
    Invoke-ConsoleFallback
    return
}

# ---- Shared UI helpers --------------------------------------------------------
$FontFamily = 'Segoe UI'
$AccentColor = [System.Drawing.Color]::FromArgb(15, 108, 189)   # #0f6cbd
$InkColor    = [System.Drawing.Color]::FromArgb(27, 29, 32)
$SoftColor   = [System.Drawing.Color]::FromArgb(95, 101, 109)
$BodyColor   = [System.Drawing.Color]::FromArgb(241, 242, 243)  # WinForms control tone
$GoodColor   = [System.Drawing.Color]::FromArgb(16, 124, 65)
$WarnColor   = [System.Drawing.Color]::FromArgb(183, 121, 31)

function New-Font([single]$size, [int]$style = 0) {
    return New-Object System.Drawing.Font($FontFamily, $size, [System.Drawing.FontStyle]$style)
}
function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [single]$size, $color, [int]$style = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Font = New-Font $size $style; $l.ForeColor = $color; $l.BackColor = $BodyColor
    if ($size -ge 11) {
        # Headings: let the label size to its own text. A fixed-height box clipped
        # the larger heading font in half at 125-150% DPI (the title looked cut).
        $l.AutoSize = $true
    } else {
        $l.Size = New-Object System.Drawing.Size($w, 22)
    }
    return $l
}
function New-TextBox([int]$x, [int]$y, [int]$w, [bool]$mask) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 26)
    $t.Font = New-Font 10
    if ($mask) { $t.UseSystemPasswordChar = $true }
    return $t
}

# ---- Build the form -----------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $FormTitle
$form.Font = New-Font 9
$form.BackColor = $BodyColor
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(430, ([int]$(if ($Mode -eq 'Install') { 392 } else { 256 })))

# Header
$form.Controls.Add((New-Label $Heading 22 16 386 12.5 $InkColor 1))
$lede = New-Label $Lede 22 52 386 9 $SoftColor
$lede.Size = New-Object System.Drawing.Size(386, 34)
$form.Controls.Add($lede)

# --- Panels: form / progress / result share the client area -------------------
$panelForm = New-Object System.Windows.Forms.Panel
$panelForm.Location = New-Object System.Drawing.Point(0, 90)
$panelForm.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - 90))
$panelForm.BackColor = $BodyColor
$form.Controls.Add($panelForm)

$panelBusy = New-Object System.Windows.Forms.Panel
$panelBusy.Location = $panelForm.Location
$panelBusy.Size = $panelForm.Size
$panelBusy.BackColor = $BodyColor
$panelBusy.Visible = $false
$form.Controls.Add($panelBusy)

# holds the field textboxes
$script:tbName = $null; $script:tbZone = $null; $script:tbCode = $null; $script:tbMaster = $null
$script:btnAction = $null

$y = 4
if ($Mode -eq 'Install') {
    $panelForm.Controls.Add((New-Label 'Nombre del equipo (opcional)' 22 $y 386 9 $SoftColor)); $y += 22
    $script:tbName = New-TextBox 22 $y 386 $false; $panelForm.Controls.Add($script:tbName); $y += 34
    $panelForm.Controls.Add((New-Label 'Zona / sucursal (opcional)' 22 $y 386 9 $SoftColor)); $y += 22
    $script:tbZone = New-TextBox 22 $y 386 $false; $panelForm.Controls.Add($script:tbZone); $y += 34
    $lblBanca = New-Label 'Codigo de banca (3 dig) *' 22 $y 386 9 $SoftColor
    $lblBanca.ForeColor = $InkColor
    $panelForm.Controls.Add($lblBanca); $y += 22
    $script:tbCode = New-TextBox 22 $y 386 $false; $panelForm.Controls.Add($script:tbCode); $y += 34
}
$lblMaster = New-Label 'Codigo maestro *' 22 $y 386 9 $SoftColor
$lblMaster.ForeColor = $InkColor
$panelForm.Controls.Add($lblMaster); $y += 22
$script:tbMaster = New-TextBox 22 $y 386 $true; $panelForm.Controls.Add($script:tbMaster); $y += 30
$hint = New-Label 'Solo el administrador lo conoce.' 22 $y 386 8 $SoftColor
$panelForm.Controls.Add($hint); $y += 30

$script:btnAction = New-Object System.Windows.Forms.Button
$script:btnAction.Text = $ActionText
$script:btnAction.Size = New-Object System.Drawing.Size(120, 32)
$script:btnAction.Location = New-Object System.Drawing.Point((430 - 22 - 120), $y)
$script:btnAction.Font = New-Font 10 1
$script:btnAction.FlatStyle = 'Flat'
$script:btnAction.FlatAppearance.BorderSize = 0
$script:btnAction.BackColor = $AccentColor
$script:btnAction.ForeColor = [System.Drawing.Color]::White
$script:btnAction.Enabled = $false
$panelForm.Controls.Add($script:btnAction)

# Enable the action only when a master code is present.
# Enable the action only when the required fields are filled: master code always,
# and (install mode) the banca code too — it is now required (it's the machine's
# identity + its order in the fleet).
$script:updateActionEnabled = {
    $ok = ($script:tbMaster.Text.Trim().Length -gt 0)
    if ($Mode -eq 'Install' -and $script:tbCode) { $ok = $ok -and ($script:tbCode.Text.Trim().Length -gt 0) }
    $script:btnAction.Enabled = $ok
}
$script:tbMaster.Add_TextChanged($script:updateActionEnabled)
if ($script:tbCode) { $script:tbCode.Add_TextChanged($script:updateActionEnabled) }

# --- Progress panel ------------------------------------------------------------
$panelBusy.Controls.Add((New-Label $ProgHeading 22 6 386 12.5 $InkColor 1))
$panelBusy.Controls.Add((New-Label 'Un momento, estamos preparando el equipo.' 22 44 386 9 $SoftColor))
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(22, 76)
$bar.Size = New-Object System.Drawing.Size(386, 16)
$bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
$panelBusy.Controls.Add($bar)
$lblStep = New-Label '' 22 100 260 9 $InkColor
$panelBusy.Controls.Add($lblStep)
$lblCount = New-Label '' 282 100 126 9 $SoftColor
$lblCount.TextAlign = 'MiddleRight'
$panelBusy.Controls.Add($lblCount)

# --- state -------------------------------------------------------------------
$script:proc = $null
$script:logPath = $null
$script:total = $TotalDefault
$script:timer = $null

function Show-Result([bool]$ok, [string]$title, [string[]]$lines, [bool]$allowRetry) {
    $panelBusy.Visible = $false
    $panelForm.Visible = $false
    $rp = New-Object System.Windows.Forms.Panel
    $rp.Location = $panelForm.Location; $rp.Size = $panelForm.Size; $rp.BackColor = $BodyColor
    $form.Controls.Add($rp)
    $mark = New-Object System.Windows.Forms.Label
    $mark.Text = $(if ($ok) { [char]0x2713 } else { '!' })
    $mark.Font = New-Font 20 1
    $mark.ForeColor = $(if ($ok) { $GoodColor } else { $WarnColor })
    $mark.Location = New-Object System.Drawing.Point(22, 6); $mark.Size = New-Object System.Drawing.Size(44, 44)
    $rp.Controls.Add($mark)
    $rp.Controls.Add((New-Label $title 74 16 340 13 $InkColor 1))
    $yy = 60
    foreach ($ln in $lines) {
        $ll = New-Label $ln 22 $yy 386 9.5 $InkColor
        $ll.Size = New-Object System.Drawing.Size(386, 22)
        $rp.Controls.Add($ll); $yy += 24
    }
    $close = New-Object System.Windows.Forms.Button
    $close.Text = $(if ($ok) { 'Finalizar' } else { 'Cerrar' })
    $close.Size = New-Object System.Drawing.Size(110, 32)
    $close.Location = New-Object System.Drawing.Point((430 - 22 - 110), ($rp.Height - 46))
    $close.FlatStyle = 'Flat'; $close.BackColor = $AccentColor; $close.ForeColor = [System.Drawing.Color]::White
    $close.FlatAppearance.BorderSize = 0; $close.Font = New-Font 10 1
    $close.Add_Click({ $form.Close() })
    $rp.Controls.Add($close)
    if ($allowRetry) {
        $retry = New-Object System.Windows.Forms.Button
        $retry.Text = 'Reintentar'
        $retry.Size = New-Object System.Drawing.Size(110, 32)
        $retry.Location = New-Object System.Drawing.Point((430 - 22 - 110 - 8 - 110), ($rp.Height - 46))
        $retry.FlatStyle = 'Flat'; $retry.Font = New-Font 10
        $retry.Add_Click({
            $form.Controls.Remove($rp)
            $script:tbMaster.Text = ''
            $panelForm.Visible = $true
            $script:tbMaster.Focus()
        })
        $rp.Controls.Add($retry)
    }
}

function Read-LogText {
    if (-not (Test-Path $script:logPath)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($script:logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $txt = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $txt
    } catch { return '' }
}

function On-Finished {
    $script:timer.Stop()
    $exit = -1
    try { $exit = $script:proc.ExitCode } catch { }
    $out = Read-LogText
    try { if (Test-Path $script:logPath) { Remove-Item $script:logPath -Force -ErrorAction SilentlyContinue } } catch { }

    if ($Mode -eq 'Install') {
        if ($exit -eq 0) {
            $bar.Value = 100
            Show-Result $true 'Todo listo' @('Configuracion aplicada', 'Conectado al panel', 'Proteccion activa') $false
        } else {
            Show-Result $false 'No se pudo completar' @('El equipo quedo en su estado normal:', 'internet sin cambios, nada a medias.', 'Puedes volver a intentarlo.') $true
        }
    } else {
        if ($exit -eq 0) {
            $bar.Value = 100
            Show-Result $true 'Listo' @('El equipo volvio a la normalidad.', 'Internet normal, sin restricciones.') $false
        } elseif ($out -match 'No hay codigo') {
            Show-Result $false 'No se puede restaurar aqui' @('Este equipo no tiene codigo de restauracion.', 'Recuperacion: reinstalar desde el panel.') $false
        } else {
            Show-Result $false 'Codigo incorrecto' @('No se realizo ningun cambio: el equipo', 'sigue exactamente igual.') $true
        }
    }
}

function On-Tick {
    $txt = Read-LogText
    if ($txt) {
        $mm = [regex]::Matches($txt, '\[(\d+)/(\d+)\]')
        if ($mm.Count -gt 0) {
            $last = $mm[$mm.Count - 1]
            $n = [int]$last.Groups[1].Value
            $tot = [int]$last.Groups[2].Value
            if ($tot -gt 0) { $script:total = $tot }
            if ($n -ge 1 -and $n -le $StepLabels.Count) { $lblStep.Text = $StepLabels[$n - 1] }
            $lblCount.Text = ('Paso {0} de {1}' -f $n, $script:total)
            $pct = [int]([math]::Min(100, ($n / [double]$script:total) * 100))
            if ($pct -ge 0 -and $pct -le 100) { $bar.Value = $pct }
        }
    }
    $done = $false
    try { $done = $script:proc.HasExited } catch { $done = $true }
    if ($done) { On-Finished }
}

function Start-Action {
    $master = $script:tbMaster.Text.Trim()
    if ($master.Length -eq 0) { return }

    $panelForm.Visible = $false
    $panelBusy.Visible = $true
    $lblStep.Text = $StepLabels[0]
    $lblCount.Text = ('Paso 1 de {0}' -f $script:total)

    $script:logPath = Join-Path $env:TEMP ('winconfig-wiz-{0}.log' -f ([guid]::NewGuid().ToString('N')))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = ('/c "{0}" > "{1}" 2>&1' -f $BatPath, $script:logPath)
    $psi.WorkingDirectory = $RootDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = 'Hidden'
    $psi.RedirectStandardInput = $true

    if ($Mode -eq 'Install') {
        $psi.EnvironmentVariables['WATCHER_MASTER_CODE'] = $master
        if ($script:tbName -and $script:tbName.Text.Trim().Length -gt 0) { $psi.EnvironmentVariables['WATCHER_MACHINE_NAME'] = $script:tbName.Text.Trim() }
        if ($script:tbZone -and $script:tbZone.Text.Trim().Length -gt 0) { $psi.EnvironmentVariables['WATCHER_MACHINE_ZONE'] = $script:tbZone.Text.Trim() }
        if ($script:tbCode -and $script:tbCode.Text.Trim().Length -gt 0) { $psi.EnvironmentVariables['WATCHER_MACHINE_CODE'] = $script:tbCode.Text.Trim() }
    }

    try {
        $script:proc = New-Object System.Diagnostics.Process
        $script:proc.StartInfo = $psi
        [void]$script:proc.Start()

        # Feed the secret through the in-memory stdin pipe, then close so the .bat's
        # pause/set-p calls see EOF. For install we send nothing (identity is in env).
        if ($Mode -eq 'Uninstall') { $script:proc.StandardInput.WriteLine($master) }
        $script:proc.StandardInput.Close()
    } catch {
        # Could not even start the process — leave the machine untouched and say so.
        $master = $null; $script:tbMaster.Text = ''
        Show-Result $false 'No se pudo iniciar' @('No se pudo iniciar la configuracion.', 'El equipo no fue modificado. Intenta de nuevo.') $true
        return
    }

    # Scrub the plaintext from our own memory as soon as it's handed off.
    $master = $null; $script:tbMaster.Text = ''

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 250
    $script:timer.Add_Tick({ On-Tick })
    $script:timer.Start()
}

$script:btnAction.Add_Click({ Start-Action })

# Enter submits when the action is enabled; Esc cancels a not-yet-started form.
$form.AcceptButton = $script:btnAction
$form.Add_Shown({ $script:tbMaster.Focus() })

[void][System.Windows.Forms.Application]::Run($form)
