# Plan 0003 — Instalador tipo asistente (WinForms) + fix ventanas negras visibles

Estado: PROPUESTO (propose-only). Decisiones ya alineadas con Felix en el artefacto
"Watcher — instalador tipo asistente". Este doc es la fuente de verdad para ejecutar
(incluso en otra sesión si esta se queda sin tokens).

## Contexto de la máquina de test
- Host `MAGARANPRUEBA`, usuario `fcmag`, IP LAN `10.0.30.222` (misma red que la Mac 10.0.30.52).
- Se está habilitando OpenSSH para que el mantenedor entre desde la Mac y verifique.
- Llave pública autorizada (única): `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDq99fZrdh71oCjV/xQ8aDDpRul415NG9JqkYZMLdKZG claude-testpc-debug`
  (privada en la Mac: `<scratchpad>/watcher_testpc_key`).

## Síntomas reportados en HW real (lo que este plan arregla)
1. **2 consolas negras visibles** que reaparecen al cerrarlas → bug de lanzamiento (abajo).
2. Internet cayó un buen rato al iniciar sesión → revisar `events.log` por SSH (causa aún sin confirmar; NO asumir).
3. No registra nada en el fleet → revisar si existe `hub-credential.json` (enroll falló) por SSH.

---

## PARTE 1 — Fix ventanas negras (URGENTE, chico) [hacer + verificar por SSH]
**Causa (confirmada en código):** las tareas del watchdog lanzan
`powershell.exe -WindowStyle Hidden -File ...`. En sesión interactiva real, powershell
crea la consola y luego la oculta → parpadea/queda visible. La tarea del proxy lo hace
bien vía `wscript RunStartupHidden.vbs` (VBS no crea consola nunca). Ya existe
`WatcherBrain/RunWatchdogLoopHidden.vbs` sin usar.

**Cambios:**
- `WatcherBrain/WatcherProxyLoop.task.xml`: `<Command>` y `<Arguments>` →
  `wscript.exe "__BRAIN_DIR__\RunWatchdogLoopHidden.vbs"` (en vez de powershell.exe).
- `WatcherBrain/WatcherProxySafetyNet.task.xml`: crear `RunSafetyNetHidden.vbs`
  (copiar patrón de RunWatchdogLoopHidden.vbs pero llamando `CheckAndStartProxy.ps1`)
  y apuntar la task a `wscript.exe "...\RunSafetyNetHidden.vbs"`.
- Verificar que RunWatchdogLoopHidden.vbs efectivamente lanza WatchdogLoop.ps1 hidden.

**Verificación (por SSH en la máquina):** re-registrar tareas
(`RegisterWatchdogTasks.ps1`), `schtasks /run`, confirmar 0 ventanas visibles en la
sesión de fcmag, y que el proxy/watchdog siguen levantando (puerto 8080).

---

## PARTE 2 — Instalador WinForms (el "embellecimiento") [A-a, decidido]
Decisiones locked (artefacto): **(A-a)** envoltura ligera WinForms; **(B)** los 4 campos
en UN solo formulario; **(C)** ventana sigue titulada «WinConfig» (disfraz). NO tocar la
lógica de `InstallWatcher.bat` (orden de regla de oro intacto).

**Diseño:**
- Nuevo `WatcherBrain/InstallerWizard.ps1` (WinForms), 3 momentos en UNA ventana «WinConfig»:
  1. **Form**: Nombre (opc), Zona (opc), Código banca 3díg (opc), **Código maestro (requerido, enmascarado •••)** + botón **Instalar**. Reemplaza los 4 InputBox de AskIdentity.ps1.
  2. **Progreso**: barra + label "Paso N de 8", alimentada parseando la salida `[n/8]` de InstallWatcher.bat corriendo OCULTO.
  3. **Listo**: check + estado (enrolada / filtrando / internet protegido) + Finalizar.
- El wizard: recoge los campos → escribe machine-name/zone/code + el master code en el
  `WATCHER_MASTER_CODE_FILE` (mismo contrato que hoy) → corre `InstallWatcher.bat` oculto
  → mapea `[1/8]..[8/8]` a la barra → muestra "Listo".
- `install.ps1` (bootstrapper) y el flujo actual: en vez de llamar directo a
  InstallWatcher.bat, lanzar `InstallerWizard.ps1` (que por dentro llama la .bat).
- Mantener un modo "silencioso/consola" de InstallWatcher.bat intacto como fallback
  (si WinForms falla, cae a los InputBox actuales — AskIdentity ya es el fallback).

**Reglas del juego (del artefacto):** título «WinConfig» (cero branding Watcher); misma
lógica por debajo; sigue pidiendo admin (UAC); código maestro requerido+enmascarado;
NO arregla el flag de SmartScreen (eso es firma de código, aparte / v2).

**Verificación (por SSH):** correr el wizard en fcmag, confirmar form único + barra +
pantalla final, y que la instalación real quedó (proxy 8080, tareas, enroll, hash de
uninstall). Screenshot vía la sesión si se puede.

---

## Orden de ejecución sugerido
1. Conectar por SSH a `fcmag@10.0.30.222` (Mac, llave del scratchpad).
2. Diagnóstico: `events.log` (internet), `hub-credential.json` (enroll), `schtasks` + puerto 8080.
3. PARTE 1 (fix ventanas) → re-registrar tareas → verificar 0 ventanas.
4. PARTE 2 (wizard) → construir → verificar en la máquina.
5. Reconstruir el bundle (`scripts/build-winconfig-bundle.sh`) y actualizar
   `watcher-fleet/public/winconfig-install.zip` (cwd = watcher-fleet para el guard) → deploy.

## Notas
- propose-only: construir en repo, Felix commitea/deploya. watcher-fleet deploy = `vercel --prod --yes`.
- Guard cross-project: para escribir en watcher-fleet, cd a watcher-fleet primero.
- Limpieza: al terminar el debug, quitar acceso SSH del test (o dejarlo, es su PC) y borrar la llave temporal.

---

## DIAGNÓSTICO EN HW REAL — 2026-07-23 (vía SSH a fcmag@10.0.30.222)
SSH: `ssh -i ~/.ssh/watcher_testpc_key -o StrictHostKeyChecking=accept-new fcmag@10.0.30.222` (llave DURABLE en ~/.ssh; OpenSSH se instaló por `winget install Microsoft.OpenSSH.Preview` porque Add-WindowsCapability/Windows Update fallaba)
(shell remoto = PowerShell; correr PS grande vía `powershell -EncodedCommand <base64 UTF-16LE>`).

Install manual en: `C:\Users\fcmag\Downloads\winconfig-install\WinConfig\WatcherBrain`.

**CAUSA RAÍZ (nueva, la más importante) — `EADDRINUSE :::8080` en loop:**
`events.log` muestra `proxy-error listen EADDRINUSE address already in use :::8080` repetido +
`watchdog-start` decenas de veces + crash/restart cíclico. Es **múltiples instancias de node
peleando por 8080**. El culpable: **`StartWatcher.vbs` SALTA el chequeo de puerto cuando el
arg es `watchdog`/`nocheck`** (por velocidad en logon, asume "solo un lanzador corre en logon").
En HW real, en el logon disparan A LA VEZ: la task WinConfig (proxy), WinConfig Loop (watchdog),
WinConfig Safety (1min) y el servicio → cada uno lanza node con skip-check → 2+ node → EADDRINUSE
→ crash loop → internet caído + varias consolas de watchdog (= las 2 ventanas negras). El VM lo
enmascaró (timing/sesión única). **Fix requerido:** que NINGÚN lanzador salte el chequeo de
puerto / usar un lock de instancia única (mutex o archivo) antes de spawnear node. Esto es P0,
va ANTES del embellecimiento.

**Otros hallazgos:**
- `CRED=False` → **enroll NUNCA funcionó** (no hay `hub-credential.json`) → por eso el fleet no
  muestra nada. Causa: internet caído (loop EADDRINUSE) durante el install. `uninstall-code.hash`
  SÍ existe (el install llegó a setearlo).
- **BackToNormal quedó incompleto:** log muestra `tamper BackToNormal ejecutado` (15:11) y DESPUÉS
  `proxy-up` → una capa (servicio/tarea) sobrevivió y relanzó el proxy. Fix: BackToNormal debe
  matar node + borrar TODAS las capas (incl. servicio) y no dejar re-armado.
- Ventanas negras: además del EADDRINUSE (multi-watchdog), sigue el fix de PARTE 1 (usar
  `RunWatchdogLoopHidden.vbs` en vez de `powershell.exe -WindowStyle Hidden`).

**Estado dejado (limpio y estable):** node matado (NODE=0), 8080 libre, `ProxyEnable=0`,
INTERNET=True. PERO quedó una **tarea programada llamada `Proxy`** que no se borró
(`schtasks /delete /tn "Proxy"` dio "cannot find file" → está en un TaskPath/subcarpeta;
borrar con `Unregister-ScheduledTask -TaskName Proxy -TaskPath <path> -Confirm:$false`).
Servicio `WinConfigSvc`: revisar si sigue.

**PRÓXIMO ORDEN (nueva sesión):** (1) borrar la tarea `Proxy` residual; (2) arreglar el
single-instance/EADDRINUSE (P0) + el hidden-window fix; (3) rebuild bundle + actualizar
`watcher-fleet/public/winconfig-install.zip` + deploy; (4) reinstalar en el test y verificar
por SSH: 1 solo node, 0 ventanas, enroll OK (CRED=True aparece en fleet), internet estable.

---

## EJECUTADO — 2026-07-23 (código P0, propose-only; falta deploy + verificación en HW)
Corrección: la tarea residual `Proxy` NO se borra — es el built-in de Windows
`\Microsoft\Windows\Autochk\Proxy` (confirmado en memoria). Se deja.

**PARTE 1 (P0) hecha en código. Todos los fixes son machine-agnostic (sirven en cada PC
nueva, no parchean solo la de test):**
1. `WatcherBrain/proxy-server.js` — **el puerto ES el lock de instancia única.** `server.on('error')`:
   en `EADDRINUSE` ahora sale limpio `process.exit(0)` (otra instancia ya escucha 8080 → esta
   sobra); antes solo logueaba y el node perdedor quedaba vivo-sin-escuchar (los `setInterval`
   lo mantenían) → fuga de node muerto en cada logon = el crash loop que tumbó el internet.
   Cualquier otro error de server → log + `exit(1)` (el watchdog reinicia). Ganador único
   garantizado sin importar cuántos lanzadores corran a la vez.
2. `WatcherBrain/StartWatcher.vbs` — **nunca salta el chequeo de puerto** (la causa raíz nombrada:
   el fast-path `watchdog`/`nocheck` asumía "un solo lanzador en logon" = FALSO en HW real).
   Acepta e ignora cualquier arg. Además lanza node oculto directo con `WshShell.Run(...,0,False)`
   (sin el wrapper `powershell -WindowStyle Hidden` que parpadea una consola).
3. `WatcherBrain/StartProxyAtLogon.bat` — guard de puerto + **PE=1 solo si el proxy escucha**
   (reusa `SetProxyByAvailability.ps1`), en vez de poner PE=1 a ciegas ANTES de arrancar node
   (eso dejaba una ventana de internet caído en cada logon).
4. Ventanas negras: `WatcherProxyLoop.task.xml` y `WatcherProxySafetyNet.task.xml` ahora lanzan
   por `wscript.exe` + VBS (`RunWatchdogLoopHidden.vbs` / nuevo `RunSafetyNetHidden.vbs`),
   creados ocultos desde el inicio, no `powershell.exe -WindowStyle Hidden`. Igual en
   `CheckAndStartProxy.ps1` (relanza el watchdog vía el VBS).
5. `WatcherBrain/WatchdogLoop.ps1` — **guard de instancia única** (al cambiar la acción de la
   task a dispara-y-sale se perdió el `MultipleInstancesPolicy`; ahora si ya corre otro
   WatchdogLoop, esta copia sale antes de tocar el PID file).
6. `BackToNormal.bat` — **completitud**: en `ADMIN_CLEANUP`, tras desinstalar el servicio y
   borrar TODAS las tasks, un `StopWatcherProcesses.ps1` + PE=0 FINAL — así lo que se haya
   relanzado durante el teardown muere después de que ya no queda capa que lo revuelva.
7. `scripts/build-winconfig-bundle.sh` — excluye TODO `docs/` del bundle público (este 0003 se
   habría colado: menciona el disfraz, IPs y la llave SSH).
8. `VERSION` → **1.0.16**.

**Bundle reconstruido:** `dist/winconfig-install-v1.0.16.zip` + `dist/winconfig-install.zip`
(76 KB, sha256 `4e758724…4e59a964`, node NO bundled → online-only). Verificado: incluye el
nuevo VBS y los task XML corregidos; sin docs/secretos.

**PENDIENTE (outward-facing — decisión/acción de Felix):** copiar el zip a
`watcher-fleet/public/winconfig-install.zip` (cd a watcher-fleet por el guard) + `vercel --prod`,
luego reinstalar en TEST 01 por SSH y verificar: 1 solo node, 0 ventanas negras, enroll OK
(CRED=True → aparece en el fleet), internet estable en el logon. NOTA: verificación de HW real
obligatoria — nada de VBS/PS/tasks se puede probar en la Mac (local-green ≠ deployed-green).

**PARTE 2 (wizard WinForms) — NO empezada** (es el embellecimiento; va después de que la Parte 1
quede verificada en HW).

---

## VERIFICADO EN HW REAL — 2026-07-23 (TEST 01, fcmag@10.0.30.222, install desatendido por SSH)
La sesión SSH corre con token de admin completo (ELEVATED=True). Instalé desatendido con el
código maestro de prod (`WATCHER-TEST-CODE-01`) vía el nuevo modo env de AskIdentity.

**Instalación 1.0.16 verde y estable:** 1 solo node, puerto 8080 UP, PE=1→127.0.0.1:8080,
tasks (WinConfig/Loop/Safety/Sync/Cleanup), servicio Running, **1 solo WatchdogLoop**,
enroll OK (CRED=True → en el fleet), hash uninstall, plaintext scrubbed. events.log:
`watchdog-start`→`proxy-up`, **cero EADDRINUSE**. Acciones de las tasks: TODAS `wscript`+VBS
(cero `powershell -WindowStyle Hidden`).

**Test de la manada del logon (lo que tumbaba la PC):** disparé las 4 capas a la vez
(WinConfig + Loop + Safety + StartWatcher) → **sigue 1 solo node, EADDRINUSE_COUNT=0**.
Recovery: maté el proxy → watchdog lo restauró en ~2s (`proxy-down` fail-open PE=0 →
`proxy-up`), golden rule respetada. Filtrado: whitelisted (google/vercel) → 200, no-whitelisted
(example.com/microsoft.com) → **404 BLOCKED**.

**DOS BUGS ADICIONALES ENCONTRADOS Y ARREGLADOS (ambos rompían PCs nuevas):**
9. `InstallWatcher.bat` — **el instalador abortaba en TODA PC nueva.** `-OutDir "%SCRIPT_DIR%"`
   pasa un path con `\` final; la `\` antes de la comilla la ESCAPA, fusiona los args y
   `-MasterCodeFile` queda sin bindear → `MissingMandatoryParameter` → "INSTALL ABORTED - NO
   MASTER CODE". Fix: `SCRIPT_DIR_NB` (sin barra final) para AskIdentity y AddAntivirusExclusion.
   (Confirmado por aislamiento: OutDir sin `\` → RC=0; con `\` → RC=1.)
10. `poll-hub.js:385` — **usaba `agent_version !== localAgentVersion`** (desigualdad, no "mayor
    que"). El hub anuncia 1.0.15; una PC recién instalada en 1.0.16 poll→**self-update DOWNGRADE
    a 1.0.15** (revirtiendo el fix EADDRINUSE) en el primer poll. Verificado EN VIVO: un poll
    manual degradó TEST 01 de 1.0.16→1.0.15. Fix (decisión de Felix): **forward-only** —
    `isNewerVersion()` (semver, solo actualiza si el hub es estrictamente mayor). Rollback =
    republicar el bueno con número mayor; el health-check+rollback local ya cubre builds malos.
    8 casos unit-test verdes. Verificado: tras el fix, 2 polls NO degradan (sigue 1.0.16, 0 backups).
11. `AskIdentity.ps1` — **modo desatendido** por env (`WATCHER_MASTER_CODE` + name/zone/code):
    habilita install remoto/automatizado (y es el seam del wizard de la Parte 2). Sin el env,
    el flujo interactivo de popups queda igual.

**VERSION → 1.0.16.** Bundle final sha256 (última build) en `dist/`. propose-only: NADA
commiteado/deployado; Felix commitea + deploya (copiar zip a watcher-fleet/public + vercel --prod
+ subir el puntero OTA del hub a ≥1.0.16).

**BUG #12 (anti-brick, pedido por Felix — el miedo de Nelson) ARREGLADO Y VERIFICADO EN HW:**
`InstallWatcher.bat` en el path `FAIL_NO_UNINSTALL` **dejaba la máquina ARMADA sin hash** si el
store del `uninstall-code.hash` fallaba (armaba pasos 2-6, luego fallaba paso 7, y NO desarmaba).
Máquina filtrando sin hash → BackToNormal fail-closed (se niega hasta a restaurar internet) →
BRICK. Esto es lo que Felix vivió (tuvo que escribir el archivo a mano). Fix (elección de Felix,
**sin tocar la crypto ni el gate**): **invariante "armado ⟺ hash"** — si no puede asegurar el hash,
DESARMA (internet normal PRIMERO, luego quita tasks/servicio/proxy/PE=0). Nunca existe una PC
"armada sin salida". Verificado EN HW inyectando un fallo del store (hash = directorio → EISDIR):
el install → `[RECUPERAR] Desarmando` → estado final TASKS=[], sin servicio, 0 proxy, PE=0,
**internet directo=200 (NO brikeado)**. Luego install limpio → sano (hash presente, 181 bytes).
NOTA: self-update YA preserva `uninstall-code.hash` (PROTECTED_RELATIVE_PATHS) → un update no lo
borra; el único hueco era este del instalador, ahora cerrado. El watchdog fail-open (PE=0 si el
proxy muere) NO tiene gate de master-code y ahora es confiable (crash loop arreglado) = la garantía
real de "internet nunca se queda caído sin necesitar el código".

**PENDIENTES:**
- Deploy (Felix): watcher-fleet/public/winconfig-install.zip + `vercel --prod` + **subir el
  puntero OTA del hub a 1.0.16** (con forward-only ya no auto-degrada, pero el hub debe anunciar
  ≥ lo instalado para que las PCs actualicen hacia adelante en el futuro).
- Enroll de TEST 01: `409 already enrolled` al re-enrolar (mi teardown borró la credencial local
  pero NO la fila del hub, keyed por MachineGuid). Artefacto de pruebas — PC nueva enrola bien.
  Para re-enrolar TEST 01: borrar su fila en el hub, luego reinstalar.
- Ojo físico "0 ventanas negras": no observable por SSH (sin desktop interactivo). Mecanismo
  probado (tasks=wscript+VBS, 0 EADDRINUSE = 0 consolas de watchdog). Confirmar en el logon
  físico / VNC si se quiere.
- BackToNormal completeness (#6): NO verificado en HW todavía (opcional).
- PARTE 2 (wizard WinForms): no empezada.
