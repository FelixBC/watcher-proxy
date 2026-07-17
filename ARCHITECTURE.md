# watcher-proxy — mapa de estructura (para desarrollo)

Guía interna del repo. El `README.txt` es para quien **instala** en la terminal;
este documento es para quien **mantiene** el agente. Agrupa los archivos de
`WatcherBrain/` por rol. (Los archivos `*.json`/`*.log`/flags que genera el
agente en runtime **no** están en git; ver la última sección.)

## Raíz del paquete
- `InstallWatcher.bat` — instalador principal (registra tareas, servicio, exclusión AV, registra con el hub).
- `BackToNormal.bat` — desinstala / desactiva y devuelve el internet a normal.
- `whitelist.txt` — sitios permitidos **por máquina** (se edita libremente; el hub nunca lo sobrescribe).
- `README.txt` — guía del usuario/instalador.
- `VERSION` — versión del agente (la lee `self-update.js` y `publish-agent.mjs`).
- `docs/` — planes (`plans/`) y `qa-test-plan.md`.

## Proxy — el motor de filtrado
- `proxy-server.js` — proxy HTTP + túnel CONNECT en `127.0.0.1:8080`; aplica el whitelist, sirve la página de bloqueo, registra bloqueos y las últimas 3 visitas permitidas.
- `whitelist-merge.js` — fusiona el whitelist compartido del hub con el local (aditivo; nunca borra lo del PC).
- `error-page.html` — página 404 que ve el usuario en un sitio bloqueado.
- `CheckPort.js` / `CheckPort.ps1` — chequeo rápido de si el puerto 8080 está abierto.

## Watchdog y auto-cura (mantener el proxy vivo, fail-open)
- `WatchdogLoop.ps1` — **capa 1**: loop de 5 s. Si el proxy cae, PRIMERO pone internet normal (fail-open) y LUEGO reinicia el proxy. Maneja el "internet libre" (unplug) contra el reloj local. Escribe eventos al log de auditoría.
- `CheckAndStartProxy.ps1` — variante en tarea programada: si el proxy está caído, internet normal → arranca Node.
- `SetProxyByAvailability.ps1` — pone el proxy de Windows ON/OFF según disponibilidad.
- `SetConnectionByte.vbs` — ajusta el byte de "conexión" del proxy (sin ventana de consola).
- `StopWatcherProcesses.ps1` — mata SOLO el proceso del proxy (excluye `self-update.js` para no auto-matar la actualización).
- `OnResumeFromSleep.bat` — re-chequea al volver de suspensión.

## Supervisión y arranque (cómo se lanza y sobrevive)
- `RegisterProxyLogonTask.ps1` — tarea programada que lanza el proxy al logon, oculto (sin ventana).
- `RegisterWatchdogTasks.ps1` — registra las capas de recuperación sobre la capa 1 (ver `docs/plans/0001`).
- `StartProxyAtLogon.bat` + `RunStartupHidden.vbs` — atajo de inicio: pone proxy ON y arranca Node, sin ventana.
- `StartWatcher.vbs` — launcher del proxy usado por el watchdog.
- `RunPollHubHidden.vbs` / `RunWatchdogLoopHidden.vbs` — launchers ocultos del poll y del watchdog loop.
- `InstallWatcherService.ps1` + `SupervisorService.ps1` + `DownloadWinSW.ps1` — **servicio real de Windows** (vía WinSW/SCM) como capa de supervisión más robusta que una segunda tarea programada.
- `WatcherProxyLoop.task.xml` / `WatcherProxySafetyNet.task.xml` / `WatcherProxySupervisor.xml` — definiciones de tareas/servicio.
- `DownloadNode.ps1` — baja el Node embebido a `WatcherBrain/node/` (carpeta autocontenida).

## Hub / flota (hablar con el dashboard watcher-fleet)
- `poll-hub.js` — el reporte cada ~5 min: manda estado (internet, proxy, filtro, bloqueos, visitas), registra transiciones de internet, y recibe instrucciones (whitelist, unplug, nombre/zona, versión, diagnóstico).
- `register-with-hub.js` — enrolamiento: cambia el secreto de enrolamiento por una credencial por-máquina (se hashea del lado servidor).
- `hub-client.js` — helpers HTTPS para hablar con el hub (módulo `https` nativo, sin librerías).
- `HubConfig.example.json` — plantilla (URL del hub + secreto). El real `HubConfig.json` está **gitignored** (secreto) — se crea al empaquetar.

## Auto-actualización
- `self-update.js` — baja el paquete DESDE EL HUB (no GitHub), verifica sha256, respalda, cambia archivos, reinicia, chequea salud y hace rollback si falla. Lock de single-flight + 3 reintentos. Nunca sobrescribe identidad/secretos.

## Diagnóstico y auditoría (local, en la PC)
- `event-log.js` — el rastro de auditoría (`events.log`): eventos de ciclo de vida y cambios de estado (proxy up/down, crashes, fail-open, internet lost/back, updates) para poder dictaminar **si falló el Watcher o la máquina/ISP**. Acotado por tiempo (15 días) y por tamaño. Solo sube si el panel lo pide.

## Identidad
- `AskIdentity.ps1` — popup en la instalación para el nombre + zona de la máquina (editable luego desde el dashboard).

## Antivirus
- `AddAntivirusExclusion.ps1` / `AddWatcherToAntivirusExclusion.bat` — exclusión en Defender.
- `FIX_ANTIVIRUS_REMOVING_PROXY.txt` — guía si el AV borra el proxy.

## Utilidades (empaquetadas, no del filtrado)
- `CleanPrintSpool.bat` / `CleanPrintSpoolOncePerDay.bat` — limpieza del spool de impresión.
- `RestoreInternetNow.bat` — fuerza a Windows de vuelta a internet normal (rescate).

## Archivos que se generan en runtime (NO en git)
Viven en `WatcherBrain/` en cada PC; se crean solos y están acotados/ignorados:
`events.log` (auditoría), `blocked-requests.log` (bloqueos), `recent-visits.json`
(últimas 3 visitas), `net-state.txt` (última reachability de internet),
`unplugged.flag` (internet libre activo), `whitelist-version.txt`,
`poll-log-cursor.txt`, `hub-credential.json` (credencial por-máquina),
`watchdog_loop.pid`, `diag-pending.flag`, `blocked-log-cleared-at.txt`,
`node/` (Node embebido).
