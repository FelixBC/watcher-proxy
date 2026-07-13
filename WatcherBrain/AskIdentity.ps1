# Shows two simple popups at install time asking for this machine's friendly
# name and its zone/branch, and writes them next to the install root so
# register-with-hub.js can send them to the dashboard. Both are optional:
# leaving a box empty means "use the Windows PC name" (name) or "no zone".
#
# Only writes a file when the user typed something, so re-running the installer
# without retyping won't wipe a name/zone that was already set.
param([Parameter(Mandatory = $true)][string]$OutDir)

try {
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Nombre de esta maquina (ejemplo: Caja 1).`r`n`r`nDejalo vacio para usar el nombre de la PC.",
        "Watcher - Nombre de la maquina",
        "")

    $zone = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Zona o sucursal (opcional, ejemplo: Sucursal Centro).",
        "Watcher - Zona",
        "")

    if ($null -ne $name -and $name.Trim().Length -gt 0) {
        Set-Content -Path (Join-Path $OutDir 'machine-name.txt') -Value $name.Trim() -Encoding UTF8 -NoNewline
    }
    if ($null -ne $zone -and $zone.Trim().Length -gt 0) {
        Set-Content -Path (Join-Path $OutDir 'machine-zone.txt') -Value $zone.Trim() -Encoding UTF8 -NoNewline
    }
} catch {
    # Never let a popup problem block the install — name/zone just fall back to
    # the hostname and can be set later from the dashboard.
    Write-Host "AskIdentity: skipped ($($_.Exception.Message))"
}
