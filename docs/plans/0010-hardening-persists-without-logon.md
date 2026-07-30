# 0010 — El hardening persiste sin depender del logon (+ retención de tickets = `tamper`)

**Status:** BUILT + verificado en HW real (2026-07-30). Gear: SINGLE-CONCERN (un área
— el hardening de entorno del agente y su wiring de tareas; sin superficie de
dinero/auth/tenancy/ADR). No toca el filtrado ni la regla de oro.

Ships as **v1.0.32** por el pipeline normal de release + OTA. El gate de staging
(plan 0003) lo valida antes de abrir a cualquier banca.

## Problema (una frase)

Los dos scripts de hardening que solo se re-aplicaban **en el logon**
(`HardenPrinters.ps1` → Keep-printed-documents = OFF, `HardenPower.ps1` → Wi-Fi
Max Performance + no dormir en AC) **nunca se re-aplican en la banca típica**,
porque el banquero deja la PC encendida y corriendo días sin apagarla — hibernada,
o solo bloqueada, muchas veces ni eso — y un trigger `onlogon` **no dispara** al
volver de hibernación ni al desbloquear.

## Background (el hecho operativo que lo origina)

**Comportamiento NORMAL del banquero, no un caso borde:** la PC se queda abierta y
corriendo por múltiples días, sin apagado intencional, frecuentemente sin
hibernar siquiera. Cualquier diseño que dependa de un reinicio o de un logon para
sanar está por definición roto en producción. Eso es lo que pasaba aquí:

- La tarea `WinConfig Cleanup At Logon` se registra con `/sc onlogon`
  (`InstallWatcher.bat`), que dispara cuando Windows **crea** una sesión
  interactiva. Al volver de hibernación/suspensión la sesión se **restaura**, y
  meter la contraseña en la pantalla de bloqueo es un *workstation unlock* — ni uno
  ni otro es un logon. (Un apagado normal + encendido sí produce logon, incluso con
  Fast Startup; la máquina expuesta es justo la que nunca se apaga.)
- La única tarea de resume que existe, `WinConfig Resume` (Power-Troubleshooter
  EventID 1), solo llama a `CheckAndStartProxy.ps1` + `SetProxyByAvailability.ps1`.
  Nada de impresoras ni de energía.
- Las tareas que sí corren cada minuto (`WatcherProxyLoop`,
  `WatcherProxySafetyNet`) corren como `BUILTIN\Users` / `LeastPrivilege`:
  estructuralmente **no pueden** cambiar config de impresora ni `powercfg`.

Ventana de exposición real: **ilimitada** (días o semanas). Si un driver, una
actualización de Windows que toca el spooler, o alguien con admin pone Keep=ON, se
queda ON hasta el próximo logon de verdad. Y `HardenPrinters.ps1` se
autodescribía como *"the CONTINUOUS guard"* — comentario falso que además tapaba
el hueco al siguiente lector.

Segundo hueco, del roadmap 0005 §D: cuando el guard revertía Keep=ON solo escribía
`printer-keep-off` en el `events.log` local, y `poll-hub.js` únicamente sube al hub
las líneas tagueadas `tamper`. El resto viaja solo si Nelson pide diagnósticos a esa
máquina. Un intento de retener tickets era, en la práctica, invisible.

## Fix

1. **`poll-hub.js` → `reassertHardeningIfDue()`**: re-aplica `HardenPrinters.ps1` +
   `HardenPower.ps1` cada ~55 min desde la tarea `WinConfig Sync`. Esa tarea es la
   única siempre-viva con los derechos necesarios (`/ru SYSTEM /rl highest`) e
   **independiente de cualquier logon**. Llega a las bancas ya instaladas por OTA sin
   registrar ninguna tarea nueva — mismo vector que usó el plan 0009.
   - **Corre ARRIBA del guard `if (!cred) return`** (hallazgo P1 de Codex, ver §Review).
     El hardening es una propiedad **local pura** — SYSTEM reescribiendo config local de
     impresora/energía — que no necesita credencial ni hub ni red, así que no debe
     acoplarse al enrollment. Una máquina que falló el enroll (código malo, 409
     anti-hijack en un reinstall, 429, o sin red al instalar) igual poletea cada 2 min y
     es JUSTO la que el operador no ve en el dashboard: dejar sus impresoras sin guard es
     el peor caso, no uno aceptable.
   - Reloj = `mtime` de `WatcherBrain/harden-last.txt`, estampado **antes** de correr
     los scripts: si uno se cuelga, el costo del timeout se paga una vez por hora, no
     en cada poll de 2 min. El stamp usa el idioma `r+` + `ftruncate` de
     `proxy-port.js` porque los archivos instalados llevan `+h +s` y un
     `writeFileSync` (CREATE_ALWAYS) haría EPERM y congelaría el reloj en silencio.
   - Cada script va con su propio `try` y `timeout: 25000`: uno que falle no salta al
     otro, y ninguno puede tumbar el poll.
   - Va **arriba** de `readNewTamperEvents()` a propósito: `HardenPrinters` escribe su
     línea de forma síncrona, así que un intento de retención se reporta en **ese
     mismo poll**, no en el siguiente.
2. **`HardenPrinters.ps1` → tag `tamper`**: revertir Keep=ON ahora escribe
   `tamper | intento de retener tickets: Keep=ON revertido en <impresoras>`, que
   `poll-hub.js` sube como `tamper_events` (cross-repo contract) → alerta roja del
   fleet.
   - Nuevo switch **`-Baseline`**, que usa solo `InstallWatcher.bat`: en la instalación
     una impresora puede traer Keep=ON por default de su driver, así que corregirlo es
     housekeeping esperado y se loguea informativo. Sin el switch (logon + poll) = algo
     lo volvió a encender **después** de que ya lo habíamos apagado = señal de robo.
     Mantener la instalación fuera del canal de tamper es deliberado: una alerta falsa
     de "intentó retener tickets" en cada instalación fresca entrenaría a Nelson a
     ignorar la alerta.
3. Comentarios corregidos donde mentían: el "CONTINUOUS guard" de
   `HardenPrinters.ps1`, y el "re-asserted every logon" de `HardenPower.ps1` +
   `CleanPrintSpoolOncePerDay.bat`, que ya no son el guard primario.

Archivos: `WatcherBrain/poll-hub.js`, `WatcherBrain/HardenPrinters.ps1`,
`WatcherBrain/HardenPower.ps1` (comentario), `WatcherBrain/CleanPrintSpoolOncePerDay.bat`
(comentario), `InstallWatcher.bat` (`-Baseline`), `.gitignore` (`harden-last.txt`),
`VERSION`.

## VERIFICADO en HW (test PC / staging, 2026-07-30 14:26–14:29Z)

Archivos parcheados a mano en la instalación del test PC (caja dedicada con
impresoras de recibo EPSON TM-T20II **reales**), luego:

| Paso | Evidencia |
|---|---|
| Armado: `Keep=ON` en `EPSON TM-T20II Receipt` + `Microsoft Print to PDF` | `KEEP_NOW=True` en ambas |
| `schtasks /run /tn "WinConfig Sync"` (corre como SYSTEM) | marker `harden-last.txt` creado, `2026-07-30T14:27:45.927Z` |
| El guard revierte | `KEEP_NOW=False` en ambas — **SYSTEM sí ve las impresoras EPSON locales** |
| Se escribe el tamper | `[2026-07-30T14:27:53.9317060Z] tamper \| intento de retener tickets: Keep=ON revertido en EPSON TM-T20II Receipt, Microsoft Print to PDF` (1 línea nueva: 272 → 273) |
| **El hub lo aceptó** | `tamper-cursor.txt` pasó de vacío a `2026-07-30T14:27:53.931Z` — el cursor solo se escribe **después** de un `postJson` exitoso, así que el evento subió |

Costo medido: ~8s de `HardenPrinters` sobre 5 impresoras (timeout 25s), una vez por
hora. La alerta roja que quedó en el dashboard para la máquina de staging es de esta
prueba, no un evento real.

## Review (Codex, carril 2 local — 2026-07-30)

`codex exec review --uncommitted`. **Carril 1 (auto en el PR) NO existe en este repo**:
verificado que los PRs #2/#3/#4 de `FelixBC/watcher-proxy` no tienen actividad de
`chatgpt-codex-connector` (la trampa de "ausencia silenciosa" de la decisión
[[codex-cross-review]]). Un solo hallazgo:

- **[P1] Hardening acoplado al enrollment** — CONFIRMADO y arreglado. `reassertHardeningIfDue()`
  estaba DEBAJO del `if (!cred) return`, así que una máquina con `HubConfig.json` pero sin
  credencial (enroll fallido / 409-invisible) poleteaba pero retornaba antes de endurecer.
  Fix: mover la llamada al tope de `main()`, arriba del guard. Verificado en HW (§VERIFICADO,
  bloque "camino no-enrolado"): con la credencial movida a un lado, el poll imprime "not
  enrolled" **y aun así** el marker avanzó (reassert corrió) y el cursor NO avanzó (sin
  upload, correcto). Divergencia: ninguna — coincidí con Codex, era un fallo real que yo
  introduje al ubicar la llamada tras el early-return.

## VERIFICADO — camino no-enrolado (test PC, 2026-07-30 ~15:18Z)

| Paso | Evidencia |
|---|---|
| Credencial movida a un lado (simula 409-invisible / enroll fallido) | `CRED_MOVED_AWAY=True` |
| `node poll-hub.js` corre una vez | `POLL_STDOUT=poll-hub: not enrolled (no credential); nothing to do.` |
| **reassert corrió ANTES del return** | marker `13:18Z` (stale −2h) → `15:18Z`, `MARKER_ADVANCED=True` |
| Sin upload (coherente con early-return) | `CURSOR_UNCHANGED=True` — máquina sin credencial no reporta |
| Impresoras siguen OFF | `KEEP=EPSON TM-T20II Receipt=False`, `KEEP=Microsoft Print to PDF=False` |
| Credencial restaurada (try/finally) | `CRED_RESTORED=True`, `BAK_GONE=True` — máquina re-enrolada limpia |

## Límites conocidos (NO cerrados por este plan)

- **Install SIN `HubConfig.json` no tiene disparador periódico** (segundo sub-caso del P1 de
  Codex). La tarea `WinConfig Sync` solo se crea si existe `HubConfig.json`
  (`InstallWatcher.bat` la mete dentro de ese `if`; el `else` solo imprime "skipping fleet
  features"), así que `poll-hub.js` nunca corre → mover la llamada no lo cubre. **Pero el
  bundle SIEMPRE trae `HubConfig.json`** (lo escribe `build-winconfig-bundle.sh`, HubUrl sin
  secreto), así que es una config manual/borde, no una banca real; y esa install igual
  conserva el guard de logon (Step 4 va fuera del gate). Cerrarlo requeriría una tarea
  periódica elevada propia, independiente del poll — **decisión de Felix**, no la tomé sola.
- **Impresoras mapeadas por usuario (`\\servidor\cola`) son invisibles a SYSTEM.**
  Viven en la hive del usuario, así que `Get-Printer` como SYSTEM no las lista. Es el
  trade que el diseño ya hacía (SYSTEM es lo único que tiene "Manage this printer"),
  no una regresión: aplica igual al camino de logon que existía antes. En el test PC
  las EPSON locales sí se ven.
- **Los trabajos YA retenidos sobreviven hasta el barrido diario.** `HardenPrinters`
  cambia el ajuste, no vacía la cola; `CleanPrintSpool.bat` (que sí vacía) corre una
  vez al día y reinicia el spooler. O sea: quien logre Keep=ON e imprima, conserva el
  trabajo reimprimible hasta ~24h aunque el ajuste se revierta en ≤1h. Cerrarlo
  requiere purgar trabajos *completados* al detectar Keep=ON, y eso arriesga matar un
  ticket que se esté imprimiendo en ese segundo — decisión de Felix, no la tomé sola.
- **Roadmap 0005 §D queda a medias**: falta detectar que **borren o desactiven** las
  tareas (`WinConfig Cleanup At Logon`, `WinConfig Sync`). Para impresoras el poll ya
  es el guard primario, así que borrar la tarea de logon ya no abre el hueco de Keep;
  borrar `WinConfig Sync` sí, y eso hoy solo se nota como máquina "sin reportar".
- Sin invariante de impresoras en la suite de self-test de staging (`self-test.js`).
