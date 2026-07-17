# Shows simple popups at install time asking for this machine's friendly name,
# its zone/branch, and its 3-digit banca code, and writes them next to the
# install root so register-with-hub.js can send them to the dashboard. All are
# optional: leaving a box empty means "use the Windows PC name" (name), "no
# zone", or "no code".
#
# Only writes a file when the user typed something, so re-running the installer
# without retyping won't wipe a value that was already set.
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

    $code = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Codigo de la banca, 3 digitos (opcional, ejemplo: 022).",
        "Watcher - Codigo de banca",
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
} catch {
    # Never let a popup problem block the install — name/zone just fall back to
    # the hostname and can be set later from the dashboard.
    Write-Host "AskIdentity: skipped ($($_.Exception.Message))"
}
