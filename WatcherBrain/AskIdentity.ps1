# Shows simple popups at install time asking for this machine's friendly name,
# its zone/branch, and its 3-digit banca code, and writes them next to the
# install root so register-with-hub.js can send them to the dashboard. Name and
# zone are optional (blank = use the PC name / no zone). The banca code is
# REQUIRED on a first install, but on a RE-VINCULACIÓN (the identity files are
# already here + already on the dashboard) it is pre-filled and optional — so
# Nelson only re-enters the master code.
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

# Re-vinculación support: if this machine was already enrolled from this folder,
# its identity files (name/zone/banca) are still here — and already on the
# dashboard. Read them to PRE-FILL the prompts and to NOT force the banca code
# again; on a re-vinculación Nelson should only have to enter the master code.
# -Force so the Hidden+System (disguised) files are readable.
function Get-ExistingField([string]$path) {
    if (Test-Path -LiteralPath $path) {
        $v = Get-Content -LiteralPath $path -Raw -Force -ErrorAction SilentlyContinue
        if ($null -ne $v) { return $v.Trim() }
    }
    return ''
}

# Write an identity file, clearing the disguise attributes first if it already
# exists — a re-vinculación's files carry +h +s from the prior install's Step 8,
# and Set-Content cannot overwrite a Hidden+System file (the same EPERM class the
# repo documents for Node). Step 8 re-applies the disguise afterwards. -Force is
# belt-and-suspenders for read-only.
function Set-Field([string]$path, [string]$value) {
    if (Test-Path -LiteralPath $path) { & attrib.exe -h -s "$path" 2>$null }
    Set-Content -LiteralPath $path -Value $value -Encoding UTF8 -NoNewline -Force
}
$existingName  = Get-ExistingField (Join-Path $OutDir 'machine-name.txt')
$existingZone  = Get-ExistingField (Join-Path $OutDir 'machine-zone.txt')
$existingBanca = Get-ExistingField (Join-Path $OutDir 'machine-code.txt')
$bancaAlreadySet = $existingBanca.Length -gt 0

# UNATTENDED PATH: when the master code is supplied via the environment
# (WATCHER_MASTER_CODE), skip the interactive popups entirely and take the
# optional identity fields from the environment too. This is what lets an
# automated / remote (SSH) install run on a machine with no interactive desktop -
# there the VB InputBox cannot render - and it is the same seam the WinForms
# installer wizard uses to drive this non-interactively. When the variable is
# absent, the interactive popup flow below is used unchanged.
if ($env:WATCHER_MASTER_CODE -and $env:WATCHER_MASTER_CODE.Trim().Length -gt 0) {
    if ($env:WATCHER_MACHINE_NAME -and $env:WATCHER_MACHINE_NAME.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-name.txt') ($env:WATCHER_MACHINE_NAME.Trim())
    }
    if ($env:WATCHER_MACHINE_ZONE -and $env:WATCHER_MACHINE_ZONE.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-zone.txt') ($env:WATCHER_MACHINE_ZONE.Trim())
    }
    # Banca code is REQUIRED on a first install (the machine's identity + its order in
    # the fleet), but a re-vinculación already has it on disk + on the dashboard, so
    # don't force it again — keep the existing one when none is supplied.
    if ($env:WATCHER_MACHINE_CODE -and $env:WATCHER_MACHINE_CODE.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-code.txt') ($env:WATCHER_MACHINE_CODE.Trim())
        # Codex P1: verify the REQUIRED banca write actually landed — a silent Set-Field failure
        # would otherwise enroll with no banca. Only enforce on a first install (a re-vinculación
        # keeps its existing one).
        $wroteCode = ''
        try { $wroteCode = (Get-Content -LiteralPath (Join-Path $OutDir 'machine-code.txt') -Raw -Force -ErrorAction Stop) } catch {}
        if ([string]::IsNullOrWhiteSpace($wroteCode) -and -not $bancaAlreadySet) {
            Write-Host "ERROR: no se pudo escribir el codigo de banca - instalacion abortada."
            exit 1
        }
    } elseif (-not $bancaAlreadySet) {
        Write-Host "ERROR: falta el codigo de banca (WATCHER_MACHINE_CODE, requerido) - instalacion abortada."
        exit 1
    }
    Set-Content -Path $MasterCodeFile -Value $env:WATCHER_MASTER_CODE.Trim() -Encoding UTF8 -NoNewline
    Write-Host "AskIdentity: modo desatendido (codigo maestro + banca tomados del entorno)."
    exit 0
}

$MaxMasterCodeAttempts = 3
$masterCodeProvided = $false
# Seed from the on-disk state: a re-vinculación's banca code is already present, so it
# counts as "provided" even if a later popup step throws — keeps the final hard-fail's
# error message honest (it won't wrongly claim the banca code is missing).
$bancaProvided = $bancaAlreadySet

try {
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Nombre de esta maquina (ejemplo: Caja 1).`r`n`r`nDejalo vacio para usar el nombre de la PC.",
        "WinConfig - Nombre de la maquina",
        $existingName)

    $zone = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Zona o sucursal (opcional, ejemplo: Sucursal Centro).",
        "WinConfig - Zona",
        $existingZone)

    # Banca code: REQUIRED on a first install (the machine's identity + its order in the
    # fleet list). On a RE-VINCULACIÓN it is already set here + on the dashboard, so show
    # it PRE-FILLED and optional — Nelson can confirm or edit, but never retypes it.
    $code = $null
    if ($bancaAlreadySet) {
        $bancaProvided = $true
        $code = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Codigo de la banca (ya registrado). Dejalo asi o editalo.",
            "WinConfig - Codigo de banca",
            $existingBanca)
    } else {
        for ($battempt = 1; $battempt -le $MaxMasterCodeAttempts; $battempt++) {
            $bprompt = if ($battempt -eq 1) {
                "Codigo de la banca, 3 digitos (REQUERIDO, ejemplo: 022)."
            } else {
                "Codigo de la banca (REQUERIDO) - intento $battempt de $MaxMasterCodeAttempts.`r`n`r`nEl campo no puede quedar vacio."
            }
            $code = [Microsoft.VisualBasic.Interaction]::InputBox($bprompt, "WinConfig - Codigo de banca", "")
            if ($null -ne $code -and $code.Trim().Length -gt 0) { $bancaProvided = $true; break }
        }
    }

    if ($null -ne $name -and $name.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-name.txt') ($name.Trim())
    }
    if ($null -ne $zone -and $zone.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-zone.txt') ($zone.Trim())
    }
    # Write the banca code only if something non-empty was entered. If Nelson cleared a
    # pre-filled (re-vinculación) code, leave the existing machine-code.txt in place.
    if ($null -ne $code -and $code.Trim().Length -gt 0) {
        Set-Field (Join-Path $OutDir 'machine-code.txt') ($code.Trim())
    }
    # Codex P1: a silent Set-Field failure would enroll with NO banca on a fresh install. If the
    # required banca file didn't actually land (and there was no pre-existing one), drop
    # $bancaProvided so the hard-fail below aborts rather than enroll with it missing.
    if ($bancaProvided -and -not $bancaAlreadySet) {
        $wroteCode = ''
        try { $wroteCode = (Get-Content -LiteralPath (Join-Path $OutDir 'machine-code.txt') -Raw -Force -ErrorAction Stop) } catch {}
        if ([string]::IsNullOrWhiteSpace($wroteCode)) { $bancaProvided = $false }
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

if (-not ($masterCodeProvided -and $bancaProvided)) {
    # Hard-fail sentinel: master code OR banca code missing after retries (or the
    # popup mechanism failed outright). Do NOT write master-code.plain. Exit non-zero
    # so InstallWatcher.bat detects this BEFORE arming anything and aborts the install
    # cleanly, leaving the machine untouched.
    Write-Host ""
    if (-not $masterCodeProvided) { Write-Host "ERROR: no se ingreso un codigo maestro (requerido) - instalacion abortada." }
    if (-not $bancaProvided) { Write-Host "ERROR: no se ingreso el codigo de banca (requerido) - instalacion abortada." }
    exit 1
}
