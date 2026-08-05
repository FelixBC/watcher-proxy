@echo off
setlocal
REM ============================================================================
REM instalar-watcher.bat -- AYUDANTE de instalacion (feature 0014).
REM
REM Nelson baja SOLO este archivo desde /descargar y le da doble-clic. El ayudante
REM hace TODO por el, para que nunca elija carpeta ni ruta:
REM   1. se auto-eleva (UAC),
REM   2. revisa colision (no pisa un Watcher vivo; limpia una carpeta muerta),
REM   3. descarga el bundle, crea C:\EPSON TMM20II, extrae ahi,
REM   4. lanza el instalador (asistente WinConfig) y le pasa SU PROPIA ruta para que
REM      el instalador lo borre de Descargas al terminar -- un proceso no se mata a
REM      si mismo, por eso lo borra el instalador (InstallWatcher.bat, paso 8).
REM
REM Es un POLIGLOTA: esta cabecera batch se auto-eleva y luego corre el PowerShell
REM del final (todo lo que sigue al marcador). El marcador se arma en dos piezas mas
REM abajo, para que esta cabecera no lo case a si misma al buscarlo.
REM ============================================================================

REM --- 1. Auto-elevar: todo lo de abajo necesita admin (crear la carpeta, ACL). ---
REM Al relanzar por RunAs, la copia elevada re-corre este .bat desde arriba: `net
REM session` pasa, salta el relanzamiento, y sigue con los params intactos (el bug
REM que el green-loop marco: elevar DESPUES perderia los parametros).
REM Guardar la ruta propia en una variable de entorno. NUNCA incrustar %~f0 en un
REM literal PowerShell con comilla simple: si la ruta trae un apostrofo (p. ej. un
REM usuario C:\Users\O'Brien\Downloads\...), el literal se cierra a media ruta y
REM PowerShell no parsea -> la elevacion/extraccion falla EN SILENCIO. Las variables
REM de entorno ($env:WCSELF) no tienen ese problema.
set "WCSELF=%~f0"

>nul 2>&1 net session
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "try { Start-Process -FilePath $env:WCSELF -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo No se dio el permiso de administrador. Vuelve a hacer doble-clic y
        echo acepta la ventana de Windows ^(UAC^) para continuar.
        echo.
        pause
    )
    exit /b
)

REM --- 2. Extraer el cuerpo PowerShell (tras el marcador) a un temp y correrlo. ---
REM La ruta va por $env:WCSELF / $env:PSF (nunca incrustada en un literal), apostrofo-safe.
set "PSF=%TEMP%\wc-ayudante-%RANDOM%%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#PS'+'BODY'; $c=Get-Content -LiteralPath $env:WCSELF -Raw; $i=$c.IndexOf($m); if($i -lt 0){ exit 9 }; Set-Content -LiteralPath $env:PSF -Value $c.Substring($i + $m.Length) -Encoding UTF8"
if not exist "%PSF%" (
    echo.
    echo No se pudo preparar el instalador. Vuelve a intentarlo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSF%" -BootstrapPath "%WCSELF%"
del /f /q "%PSF%" >nul 2>&1
endlocal
exit /b

#PSBODY
param([string]$BootstrapPath)

# ---- Cuerpo del ayudante (corre elevado, invocado por la cabecera batch) ----
$ErrorActionPreference = 'Stop'

$Parent = 'C:\EPSON TMM20II'
$Target = Join-Path $Parent 'WinConfig'
# El bundle se sirve estatico desde /descargar (mismo host que sirvio este ayudante).
$ZipUrl = 'https://watcher-fleet.vercel.app/winconfig-install.zip'

function Say([string]$m){ Write-Host $m }
function Fail([string]$m){
    Write-Host ''
    Write-Host "ERROR: $m"
    Write-Host 'No se instalo nada; el equipo quedo igual.'
    try { Read-Host 'Presiona Enter para cerrar' | Out-Null } catch {}
    exit 1
}

Write-Host ''
Write-Host '  Instalando WinConfig...'
Write-Host ''

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Paso 1: COLISION. ¿Hay un Watcher VIVO? (cualquier senal de vida -> parar) ---
# Señal por el PROXY, no por un glob que se salte la tarea base (green-loop Obj 2):
#   (a) cualquier tarea programada WinConfig* (INCLUIDA la base "WinConfig" sin sufijo),
#   (b) node corriendo desde la carpeta destino,
#   (c) el puerto obscuro del proxy escuchando (leido de proxy-port.txt).
$live = $false
# Una sonda que LANZA excepcion (no que devuelve "no hay") = no se pudo evaluar. En una
# banca mal mantenida (WMI corrupto, etc.) tragarse eso y seguir borraria un install VIVO.
# Rastreamos ese caso aparte y fallamos CERRADO abajo (green-loop/revisor: fail-open bug).
$probeFailed = $false
# -ErrorAction STOP (no SilentlyContinue): con SilentlyContinue el error se traga ANTES
# del catch y $probeFailed nunca se pone -> el fallar-cerrado no dispararia (Codex ronda 2).
# Con Stop, un fallo REAL del cmdlet lanza -> catch -> probeFailed; un "no hay nada" normal
# devuelve vacio SIN lanzar (Get-ScheduledTask/Get-CimInstance no lanzan por no-match).
try {
    if (Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -like 'WinConfig*' }) { $live = $true }
} catch { $probeFailed = $true }
if (-not $live) {
    $nodeExe = Join-Path $Target 'WatcherBrain\node\node.exe'
    try {
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)) {
            if ($p.ExecutablePath -and ($p.ExecutablePath -ieq $nodeExe)) { $live = $true; break }
        }
    } catch { $probeFailed = $true }
}
if (-not $live) {
    $portFile = Join-Path $Target 'WatcherBrain\proxy-port.txt'
    if (Test-Path $portFile) {
        try {
            $port = [int]((Get-Content -LiteralPath $portFile -Raw).Trim())
            # Consultar TODOS los listeners y filtrar por puerto: Get-NetTCPConnection -LocalPort
            # LANZA en "no match", lo que con -ErrorAction Stop daria un fail-closed FALSO. Pedir
            # todos (siempre hay algun listener -> no lanza) y filtrar despues -> Stop solo dispara
            # en un fallo real del cmdlet.
            if ($port -gt 0 -and (Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $port })) { $live = $true }
        } catch { $probeFailed = $true }
    }
}
if ($live) {
    Write-Host ''
    Write-Host '  Ya hay un Watcher instalado y funcionando en esta PC.'
    Write-Host '  No se toco nada.'
    Write-Host ''
    Write-Host '  Para reinstalar: desinstalalo primero con Uninstall.exe y borra'
    Write-Host '  la maquina del panel; luego vuelve a correr este instalador.'
    Write-Host ''
    try { Read-Host 'Presiona Enter para cerrar' | Out-Null } catch {}
    exit 0
}
# FALLAR CERRADO ante la duda: si alguna sonda no se pudo evaluar y no vimos vida, NO
# borres nada -- podria estar vivo. Mandar a desinstalar a mano en vez de arriesgar.
if ($probeFailed) {
    Write-Host ''
    Write-Host '  No se pudo confirmar con seguridad el estado de este equipo.'
    Write-Host '  Por precaucion no se toco nada.'
    Write-Host ''
    Write-Host '  Si ya hay un Watcher, desinstalalo primero con Uninstall.exe;'
    Write-Host '  si no, contacta a soporte.'
    Write-Host ''
    try { Read-Host 'Presiona Enter para cerrar' | Out-Null } catch {}
    exit 0
}

# --- Destino ocupado por algo AJENO -> rechazar, NO instalar encima (Codex ronda 2 P2). ---
# Si $Target existe pero no tiene WatcherBrain, no es nuestra carpeta: no la pisamos (ni su
# ACL ni sus archivos). Solo seguimos si NO existe (install fresco) o si es nuestra (paso 2).
if ((Test-Path $Target) -and -not (Test-Path (Join-Path $Target 'WatcherBrain'))) {
    Write-Host ''
    Write-Host '  Ya existe una carpeta en el destino que no parece de WinConfig.'
    Write-Host '  Por precaucion no se toco nada. Contacta a soporte.'
    Write-Host ''
    try { Read-Host 'Presiona Enter para cerrar' | Out-Null } catch {}
    exit 0
}

# --- Paso 2: carpeta MUERTA (un Watcher viejo ya desinstalado). Limpiar. ---
# Solo si es de VERDAD una carpeta nuestra (tiene WatcherBrain) y sin senales de vida
# (ya verificado arriba). Regla de oro: normalizar internet ANTES de borrar nada.
if (Test-Path (Join-Path $Target 'WatcherBrain')) {
    Say '  Limpiando una instalacion anterior inactiva...'
    # Normalizar internet ANTES de borrar (regla de oro). NOTA (Codex P1, DIFERIDO): este HKCU
    # es el hive de la cuenta que ELEVO; si el banquero es usuario estandar y el UAC lo aprobo
    # OTRA cuenta admin, esto no toca el proxy del usuario logueado. Es un patron PRE-EXISTENTE
    # en todo el repo (BackToNormal/InstallWatcher igual) y aqui el impacto es bajo (la carpeta
    # muerta ya no tiene proxy corriendo). Arreglarlo bien (cargar el hive del usuario interactivo)
    # es un cambio repo-wide aparte, no de 0014.
    try {
        reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f | Out-Null
        reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f 2>$null | Out-Null
    } catch {}
    # Borrar SOLO la carpeta que validamos como nuestra ($Target = ...\WinConfig), NUNCA
    # el padre entero -- ese nombre se eligio para PARECER una carpeta Epson y podria
    # compartir algo. El padre se quita aparte, solo si quedo vacio (Codex/revisor).
    try { Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop }
    catch { Fail "no se pudo limpiar la instalacion anterior ($($_.Exception.Message)). No se instalo encima." }
    try {
        if ((Test-Path $Parent) -and -not (Get-ChildItem -LiteralPath $Parent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $Parent -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# --- Paso 3: crear + endurecer la carpeta WinConfig (mismo modelo que install.ps1) ---
Say '  Preparando la carpeta...'
try {
    # New-Item crea $Parent y $Target de una. El ACL va SOLO en $Target (la carpeta
    # WinConfig), como install.ps1 con su InstallDir -- NO en el padre disfrazado, que
    # podria compartirse con algo Epson real (Codex/revisor).
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    # SIDs bien conocidos (independientes del idioma): Admins=544, SYSTEM=18, Users=545.
    icacls $Target /inheritance:r | Out-Null
    icacls $Target /grant:r "*S-1-5-32-544:(OI)(CI)F" | Out-Null
    icacls $Target /grant:r "*S-1-5-18:(OI)(CI)F" | Out-Null
    icacls $Target /grant:r "*S-1-5-32-545:(OI)(CI)M" | Out-Null
} catch { Fail "no se pudo crear la carpeta ($($_.Exception.Message))." }

# --- Paso 4: descargar el bundle ---
Say '  Descargando...'
$zip = Join-Path $env:TEMP ("wc-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
try { Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing }
catch { Fail "no se pudo descargar ($($_.Exception.Message)). Revisa el internet e intenta de nuevo." }

# --- Paso 5: extraer al Parent (la carpeta tope del zip es 'WinConfig' -> $Target) ---
Say '  Extrayendo...'
try { Expand-Archive -Path $zip -DestinationPath $Parent -Force }
catch { Remove-Item $zip -Force -ErrorAction SilentlyContinue; Fail "no se pudo extraer ($($_.Exception.Message))." }
Remove-Item $zip -Force -ErrorAction SilentlyContinue

$wizard = Join-Path $Target 'WatcherBrain\WinConfigWizard.ps1'
$bat = Join-Path $Target 'InstallWatcher.bat'
if (-not (Test-Path $bat)) { Fail 'el paquete quedo incompleto (falta InstallWatcher.bat).' }

# --- Paso 6: entregar al instalador, diciendole NUESTRA ruta para que se auto-limpie ---
# El instalador (InstallWatcher.bat, paso 8, exito) borra este .bat de Descargas; el
# asistente muestra el aviso en pantalla. Lanzamos SIN -Wait para no dejar este .bat
# bloqueado cuando el instalador lo borre.
$env:WATCHER_BOOTSTRAP_PATH = $BootstrapPath
if (Test-Path $wizard) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Install' -f $wizard) `
        -WorkingDirectory $Target
} else {
    Start-Process -FilePath $bat -WorkingDirectory $Target
}
