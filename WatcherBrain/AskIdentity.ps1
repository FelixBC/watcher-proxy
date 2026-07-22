# Shows simple popups at install time asking for this machine's friendly name,
# its zone/branch, and its 3-digit banca code, and writes them next to the
# install root so register-with-hub.js can send them to the dashboard. Name/
# zone/banca-code are optional: leaving a box empty means "use the Windows PC
# name" (name), "no zone", or "no code".
#
# The master code is DIFFERENT: it is REQUIRED. Without it there is no
# uninstall-code.hash, which means BackToNormal fails closed and the machine
# ends up enrolled-less and un-uninstallable. So a blank/cancelled master code
# re-prompts (a few attempts) and, if still empty, this script exits non-zero
# WITHOUT writing master-code.plain — InstallWatcher.bat checks that exit code
# and aborts the whole install cleanly, before arming anything.
#
# Only writes a file when the user typed something, so re-running the installer
# without retyping won't wipe a value that was already set.
#
# FIX 1: the master-code plaintext does NOT go into $OutDir (the install root),
# because C:\WinConfig is user-readable (BUILTIN\Users:Modify). It is written to
# $MasterCodeFile instead - a path the elevated installer picks inside its own
# %TEMP% (Admin/SYSTEM-only). The optional machine-name/zone/code files are not
# secret and stay in $OutDir as before.
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$MasterCodeFile
)

$MaxMasterCodeAttempts = 3
$masterCodeProvided = $false

try {
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Nombre de esta maquina (ejemplo: Caja 1).`r`n`r`nDejalo vacio para usar el nombre de la PC.",
        "WinConfig - Nombre de la maquina",
        "")

    $zone = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Zona o sucursal (opcional, ejemplo: Sucursal Centro).",
        "WinConfig - Zona",
        "")

    $code = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Codigo de la banca, 3 digitos (opcional, ejemplo: 022).",
        "WinConfig - Codigo de banca",
        "")

    if ($null -ne $name -and $name.Trim().Length -gt 0) {
        Set-Content -Path (Join-Path $OutDir 'machine-name.txt') -Value $name.Trim() -Encoding UTF8 -NoNewline
    }
    if ($null -ne $zone -and $zone.Trim().Length -gt 0) {
        Set-Content -Path (Join-Path $OutDir 'machine-zone.txt') -Value $zone.Trim() -Encoding UTF8 -NoNewline
    }
    if ($null -ne $code -and $code.Trim().Length -gt 0) {
        Set-Content -Path (Join-Path $OutDir 'machine-code.txt') -Value $code.Trim() -Encoding UTF8 -NoNewline
    }

    # Master code (REQUIRED): the shared secret the administrator controls. It is
    # used ONCE for enrollment and to derive the salted uninstall hash, then the
    # plaintext is scrubbed by the installer. It is NEVER kept on this machine.
    # A blank/cancelled entry (VB's InputBox returns "" for both) re-prompts up
    # to $MaxMasterCodeAttempts times instead of silently continuing.
    $masterCode = $null
    for ($attempt = 1; $attempt -le $MaxMasterCodeAttempts; $attempt++) {
        $prompt = if ($attempt -eq 1) {
            "Codigo maestro de instalacion (REQUERIDO).`r`n`r`nSolo el administrador debe conocerlo. Se usa para enrolar y para desinstalar; no se guarda en texto en este equipo."
        } else {
            "Codigo maestro de instalacion (REQUERIDO) - intento $attempt de $MaxMasterCodeAttempts.`r`n`r`nEl campo no puede quedar vacio. Solo el administrador debe conocerlo."
        }
        $masterCode = [Microsoft.VisualBasic.Interaction]::InputBox(
            $prompt, "WinConfig - Codigo maestro", "")

        if ($null -ne $masterCode -and $masterCode.Trim().Length -gt 0) {
            $masterCodeProvided = $true
            break
        }
    }

    if ($masterCodeProvided) {
        # Transient plaintext, written to the installer's Admin/SYSTEM-only $MasterCodeFile
        # (NOT the user-readable install root): consumed by register-with-hub.js (enroll)
        # and then converted to a salted hash + deleted by InstallWatcher.bat Step 7.
        Set-Content -Path $MasterCodeFile -Value $masterCode.Trim() -Encoding UTF8 -NoNewline
    }
} catch {
    # Never let a popup problem block the OPTIONAL fields — name/zone/code just
    # fall back to defaults and can be set later from the dashboard. The master
    # code is a different story (see the hard-fail check below): if the popup
    # mechanism itself failed here, $masterCodeProvided is still false, so that
    # check catches this path too and aborts the install exactly the same as a
    # blank/cancelled prompt.
    Write-Host "AskIdentity: popup error ($($_.Exception.Message))"
}

if (-not $masterCodeProvided) {
    # Hard-fail sentinel: no master code captured after retries (or the popup
    # mechanism failed outright). Do NOT write master-code.plain. Exit non-zero
    # so InstallWatcher.bat detects this BEFORE arming anything and aborts the
    # install cleanly, leaving the machine untouched.
    Write-Host ""
    Write-Host "ERROR: no se ingreso un codigo maestro (requerido) - instalacion abortada."
    exit 1
}
