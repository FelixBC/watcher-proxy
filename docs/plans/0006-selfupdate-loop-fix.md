# Plan 0006 — Fix del loop de self-update (P0 del OTA 1.0.28)

Estado: **LOCKED v2 — aprobado por Felix 2026-07-24 (AC4 v1 diferido).** El repro empírico
de hoy REFUTÓ el mecanismo asumido del statement v1 (retención de puerto por `Stop-Process -Force`).
El contrato operativo es la **RE-DEFINICIÓN v2** de abajo; el statement v1 se conserva como histórico
del recorrido diagnóstico. Gear: **FULL-ORCHESTRATOR** (sin cambio). Siguiente fase tras la aprobación:
RESEARCH→SOLVE/green-loop→DECOMPOSE→IMPLEMENT→VERIFY (reviewer separado + repro real en la test PC
como gate E2E, colaborativo: Felix publica el OTA de prueba, el agente verifica por fleet+SSH).

---

## RE-DEFINICIÓN v2 (2026-07-24) — diagnóstico corregido por repro empírico

### Diagnóstico (ground truth — reemplaza el mecanismo v1)
Fuentes: `update.log` + `events.log` del loop real `1.0.27→1.0.28` (~44 min, test PC) + repro aislado
en el puerto 49999. Hechos por ciclo (×22): `Checksum OK` + `New files copied in` (el swap SÍ tiene
éxito) → `Post-update health check FAILED — rolling back` (21×) → `Rollback did not come up healthy
either` (21×). Pero `events.log` muestra **23× `proxy-up | escuchando 127.0.0.1:49732`** (cero
`proxy-dup-exit`, cero `proxy-crash`): **el proxy bindea perfecto cada ciclo.** Correlación de tiempos:
el `proxy-up` real ocurre **16–32s DESPUÉS** de que el health check ya declaró FAILED. End-to-end
"files copied in → listening" ≈ **60–90s** (cold-start de node bajo el re-escaneo de Defender del árbol
recién swapeado). El health window es 15s.

**REFUTADO** (con evidencia): (a) `Stop-Process -Force` NO retiene el puerto — hace cierre abortivo/RST,
puerto libre en <0.5s (medido, 0 y 12 túneles vivos en proceso separado); (b) TIME_WAIT no bloquea un
`listen()` INADDR_ANY en Win11 (libuv usa `SO_EXCLUSIVEADDRUSE`; 52 TIME_WAIT reales → rebind SUCCESS);
(c) el `EADDRINUSE→exit(0)` NO es la causa (0 eventos dup-exit; el proxy bindea). El mecanismo v2 abajo.

### Problem (una frase)
Cuando un agente instalado se auto-actualiza, el proxy nuevo bindea bien pero su cold-start post-swap
(~60–90s) excede el health check ciego de 15s del updater (`self-update.js waitForHealthy(5,3000)`),
que hace **rollback de un proxy sano-pero-lento**; como el rollback revierte `VERSION` y `poll-hub.js`
re-dispara el mismo update cada 2 min **sin cooldown de versión fallida**, y `SetProxyByAvailability`
fuerza `ProxyEnable=0` toda la ventana, el filtro queda **apagado (fail-open) ~44 min** en loop.

### Acceptance criteria v2 (numeradas, testables — gate = repro real en la test PC)
1. **No-loop (E2E):** en un update N→N+1 en la test PC, converge en **UN solo ciclo** — un `proxy-up`
   del binario N+1, `VERSION`=N+1, sin 2º `_backup_*`, **sin ningún `Post-update health check FAILED`**,
   sin rollback — **aunque el cold-start tarde ~60–90s**. El loop no reaparece.
2. **Health check paciente vs cold-start (`self-update.js`):** el updater NO hace rollback de un proxy
   que está subiendo dentro de la ventana de cold-start REAL. Observable: no dispara "health check
   FAILED — rolling back" para un proxy que sí llega a `proxy-up`. La paciencia sale de un cold-start
   MEDIDO (AC6), no de 15s a ciegas. (Solución-agnóstico: extender la paciencia O decoplar "update
   aplicado" de "proxy arriba ahora" — decisión de SOLVE.)
3. **Cooldown de versión fallida (`poll-hub.js`) — [movido de non-goal a scope, endosado por Felix]:**
   si un update a la versión X falla (rollback), el agente NO re-dispara el update a esa MISMA X en cada
   poll de 2 min; respeta un cooldown persistido. Una versión ESTRICTAMENTE más nueva que X evita el
   cooldown (forward-only, afín a `isNewerVersion` ya existente). Testable: tras un fallo a X, los polls
   dentro del cooldown NO re-lanzan self-update a X; un hub que anuncia X+1 sí actualiza.
4. **Filtro restaurado tras update exitoso:** tras converger, `ProxyEnable=1` y un sitio no-whitelisteado
   (ej. supercarros) queda **BLOQUEADO** dentro de un tiempo acotado post-`proxy-up`. Sin ventana
   fail-open indefinida.
5. **Fail-CLOSED preservado (catch `self-update.js` ~L413):** si el update lanza error ANTES del flip a
   internet normal (download/checksum), la ruta de error nunca deja Windows apuntando a un proxy muerto
   con `ProxyEnable=1` — pone internet normal PRIMERO y solo mata/restaura si el install se tocó de
   verdad. Testable: forzar fallo de download/checksum → internet arriba (fail-open), proxy viejo
   intacto sigue filtrando, sin ventana de internet-cero.
6. **Duraciones MEDIDAS, no adivinadas:** la paciencia del health check sale de un **cold-start del
   proxy MEDIDO en la test PC** (no de una retención de puerto — inexistente), documentado aquí, y el
   agente arreglado se valida en un repro real ANTES de re-publicar el OTA.
7. **Golden rule fail-open intacto (`ARCHITECTURE.md` §Watchdog):** ninguna ruta del fix deja
   `ProxyEnable=1` apuntando a un proxy que no escucha; no se introduce ninguna ventana fail-CLOSED nueva.

### Non-goals v2 (explícitos)
- **AC2 v1 DESCARTADO** (desambiguar `EADDRINUSE` + retry-con-backoff para "superar la retención"):
  apunta a un modo de fallo **inexistente**. El `exit(0)` del hermano legítimo (puerto = lock) se deja
  **intacto** (no es la causa).
- **NO** acelerar el cold-start del proxy. Investigar la exclusión de Defender sobre el árbol swapeado /
  `%TEMP%/_update` es una palanca ALTERNATIVA (seguimiento) — el fix mínimo es "paciencia + no
  re-loopear", no "acelerar node".
- **NO** cambiar entrega/publicación OTA, hub, ni dashboard (más allá de re-publicar 1.0.29 + retirar
  la fila OTA 1.0.28).
- **NO** cambiar el modelo de lock de instancia única (puerto = lock).
- **NO** tocar identidad/secretos/enrolamiento.
- **NO** implementar el resto del backlog de hardening (health por identidad/versión completo, lock
  atómico, whitelist atómico, drenado de túneles CONNECT, etc.).
- **AC4 v1 (whitelist vacío = last-known-good):** NO implicado en el loop → **diferido** a seguimiento,
  salvo que Felix lo quiera dentro (open question 3).

### Contracts & ADR-locked areas touched (v2)
- **`ARCHITECTURE.md` §Watchdog golden rule fail-open:** CONSUME y PRESERVA; AC5/AC7 lo enfuerzan. No
  cambia el contrato.
- **`self-update.js`** (paciencia del health / rollback) + **`poll-hub.js`** (cadencia de trigger +
  nuevo estado de cooldown persistido) + posiblemente **`SetProxyByAvailability.ps1`** (restaurar
  filtro): CONSUME; el fix ajusta paciencia + añade estado de cooldown, mantiene la forma del contrato
  cross-repo (poll/OTA sin cambio de shape).
- **No hay `docs/adr/`.** No se altera decisión bloqueada. **No requiere ADR.**

### Recommended gear: **FULL-ORCHESTRATOR** (sin cambio) — risk surface: ruta de self-update.

### Open questions v2
1. **[RESUELTA por el repro]** Mecanismo: cold-start >15s + sin cooldown + `ProxyEnable=0` toda la
   ventana. NO retención de puerto.
2. **[abierta — se cierra en build/SOLVE]** Número exacto de cold-start para calibrar AC2/AC6 (medición
   limpia en la test PC; base actual log-derived ~60–90s).
3. **[RESUELTA — Felix 2026-07-24]** AC4 v1 (whitelist vacío): **DIFERIDO** a un PR de seguimiento
   (no implicado en el loop; el fix se mantiene enfocado).
4. **[abierta — SOLVE]** Diseño del cooldown (por tiempo vs. "no reintentar misma versión hasta hub más
   nuevo") y del fix de paciencia (extender `waitForHealthy` vs. decoplar update-aplicado de proxy-arriba).

---

## Approach decidido (SOLVE — 2026-07-24, green-loop 2 rondas → STOP)

**Approach 1-REFINED** (health check paciente + cooldown de versión fallida + envelope de seguridad).
Rechazados: Approach 2 (no-rollback → crash-loop: una versión rota deja la máquina sin filtro para
siempre, sin recuperación) y Approach 3 (health por identidad/versión = hardening diferido, over-scope).
El critic (agente separado, opus, 2 rondas) forzó todo lo de abajo; detalle completo en el diseño de
build. Sub-fixes:

- **A — `self-update.js` ventanas:** post-update health = techo GENEROSO (~300s; el check retorna
  apenas abre el puerto, así que el techo es "gratis" para un proxy sano y cubre bancas lentas — AC6 =
  techo generoso, no un número ajustado a 91s). Post-rollback = CORTO (15s, no gatea nada crítico).
  Limpiar `updating.flag` justo tras el `startProxyAndWatchdog` del rollback (refiltra ASAP).
- **B — [BLOCKER] guard de staleness del `updating.flag` en las 3 capas** (`SetProxyByAvailability.ps1`,
  `WatchdogLoop.ps1`, `CheckAndStartProxy.ps1`): flag más viejo que `STALE_FLAG_MINUTES=15` → tratar como
  AUSENTE (auto-sana un flag huérfano si self-update muere antes del finally). **TZ pin obligatorio:**
  `LastWriteTimeUtc` vs `(Get-Date).ToUniversalTime()` (ambos UTC), espejo de `WatchdogLoop.ps1:97-98` —
  la resta ingenua UTC-vs-local rompería el guard SOLO en la flota Eastern (invisible en tests UTC).
- **C — cooldown de versión fallida:** `self-update.js` escribe `WatcherBrain/update-failed.json`
  `{version: argVersion, failedAt}` SOLO en la ruta health-fail (no en fallo de descarga), DESPUÉS de
  `restoreBackup`. `poll-hub.js` lo honra: `candidate === marker.version && now-failedAt < 60min` → skip;
  `isNewerVersion(candidate, marker.version)` → bypass + clear; clear en éxito. Comparar contra
  **marker.version**, nunca `VERSION`. Tratamiento de 3 lugares: `PROTECTED_RELATIVE_PATHS` + `.gitignore`
  + guard del bundle (`build-winconfig-bundle.sh:198`). Read con try/catch (JSON malo → sin cooldown).
- **D — catch fail-closed (AC5):** `swapStarted` (true justo antes del swap); en el catch, `!swapStarted`
  → NO tocar nada (proxy viejo vivo, PE=1, filtrando); `swapStarted` → stop/restore actual. NO
  flip-primero-siempre (mataría un proxy sano en cada hipo de CDN).
- **E — filtro restaurado (AC4):** cubierto por A+B + el watchdog existente (PE=1 ≤1min tras limpiar el
  flag). Sin código extra.

**Blast radius: 7 archivos** — `self-update.js`, `poll-hub.js`, `SetProxyByAvailability.ps1`,
`WatchdogLoop.ps1`, `CheckAndStartProxy.ps1`, `scripts/build-winconfig-bundle.sh`, `.gitignore`.
(Los 3 `.ps1` del watchdog son la expansión que forzó el BLOCKER — requeridos para que la ventana larga
sea SEGURA.) **Residual (nombrado para el gate E2E):** el health por-puerto no distingue el binario N de
N+1 → AC1 "proxy-up del binario N+1" se verifica EXTERNAMENTE (VERSION + events.log), no por el health.

## Verificación QA en hardware real (2026-07-25) — 6/6 verde, hub-free en la test PC

Todo probado en la test PC sin tocar el hub de producción (cero blast radius; test bundles servidos por
un http local, `downloadFile` acepta `http://`).

- **Follow-up A (`self-update.js`):** `checkTcpOpenSync` (spawn de powershell por chequeo) → `checkTcpOpen`
  **in-process (`net.connect`)**. Medido: la ventana paciente pasó de **~555s → ~313s** (100 chequeos ya
  no arrancan un proceso c/u). Codex cross-review limpio (solo re-señaló el bootstrapping ya conocido).
- **QA1 — internet NUNCA cae (la preocupación central):** probe (TCP directo a 1.1.1.1 + HTTP por la
  config de proxy actual, distinguiendo 404-bloqueado de FAIL-de-conexión) corrido sobre update bueno +
  malo + lento → **0 violaciones de golden-rule en miles de muestras.** El camino del navegador siempre
  alcanzable (200 sin filtro durante la ventana / 404 filtrado); PE alterna 1→0→1; **internet arriba todo
  el tiempo.**
- **QA2 — flag huérfano:** flag fresco → PE=0 (el watchdog se para); flag de 20min (backdated) → PE=1
  (auto-sana). Prueba el stale-guard Y que el **TZ-pin es correcto en la Eastern** (fresco no se lee stale).
- **QA3 — fallo pre-swap (AC5):** sha errado → "aborted before touching the install", el proxy viejo
  nunca se toca, ni un flip de PE.
- **QA4 — cooldown → poll-hub saltea:** hub falso local anunciando una versión en cooldown → el poll-hub
  REAL loguea `update-cooldown` y NO dispara self-update (HubConfig repuntado y luego RESTAURADO al real).
- **QA5 — cold-start lento:** un proxy que escucha ~45s tarde → la paciencia esperó ~46s y **convergió**
  (no rollback) — el caso que los tests rápidos no estresaban.
- Más: test de lógica del cooldown **8/8** (incl. el caso P2 de Codex).

Diff final: **7 archivos de código** (los mismos de v2; el follow-up A son más cambios dentro de
`self-update.js`, ya contado). Todo propose-only,
sin commit. Pendiente para el rollout: install manual de la versión arreglada a las bancas en 1.0.28
(no se puede OTA-ear el fix a través del bug), y la decisión de flota/hub-targeting antes de publicar.

## [SUPERSEDED v1 — histórico] Statement original (mecanismo REFUTADO por el repro 2026-07-24)

> El texto de abajo era el statement LOCKED v1. Su mecanismo asumido — "matar con `Stop-Process -Force`
> retiene el puerto minutos → `EADDRINUSE→exit(0)` → nadie escucha → health falla → loop" — fue
> **refutado empíricamente**. Se conserva como registro del recorrido diagnóstico; el contrato operativo
> es la RE-DEFINICIÓN v2 de arriba.

## Problem (una frase)

## Problem (una frase)
Cuando un agente instalado se auto-actualiza, matar el proxy viejo con `Stop-Process -Force` deja
el puerto retenido por el SO durante minutos; el handler de `EADDRINUSE` del proxy nuevo hace
`exit(0)` en vez de reintentar, así que **nadie escucha**, el health check de 15s falla en falso, y
el rollback + re-poll **sin cooldown** deja el filtro apagado (fail-open) indefinidamente
(verificado en vivo, ~44 min en la test PC) — y dos rutas fail-CLOSED independientes pueden dejar
la máquina **sin internet**.

## Acceptance criteria (numeradas, testables)
1. **No-loop:** en un repro controlado en la test PC, un update de versión N→N+1 llega a un proxy
   N+1 **sano y filtrando en UN solo ciclo** — sin rollback, sin un 2º `_backup_*`, `VERSION`
   termina en N+1, `ProxyEnable=1`, y un sitio no-whitelisteado (ej. supercarros) queda
   **BLOQUEADO** tras el update. El loop no reaparece.
2. **EADDRINUSE desambiguado (`proxy-server.js` ~L483):** con un proxy hermano vivo ya escuchando →
   `exit(0)` (lock de instancia única + comportamiento logon-herd intactos); sin nadie escuchando
   (puerto retenido) → **retry con backoff** suficiente para superar la retención medida del SO,
   y solo falla non-zero si de verdad no puede bindear. Observable: el proxy nuevo termina bindeando
   dentro de un ciclo, sin salir prematuro.
3. **Updater paciente (`CheckPort.ps1`):** mientras exista `updating.flag`, espera la ventana de
   recuperación antes de reportar fallo, para que el `waitForHealthy` del updater viejo NO haga
   rollback a los ~15s. Observable: en el repro, no dispara "health check FAILED — rolling back"
   para un proxy que sí sube.
4. **Fail-CLOSED #1 (whitelist vacío):** si la lectura del whitelist falla o queda momentáneamente
   vacía/rota, el proxy **NO** sirve un whitelist vacío que bloquee todo — reintenta / preserva
   last-known-good, o no se reporta "sano" hasta cargar un whitelist no-trivial. Testable: simular
   lectura fallida/archivo vacío → el proxy no bloquea el 100% de los dominios permitidos.
5. **Fail-CLOSED #2 (catch del self-update ~L413):** si falla el download/checksum (proxy viejo
   intacto), la ruta de error **nunca** deja a Windows apuntando a un proxy muerto — pone internet
   normal PRIMERO y solo mata/restaura si el install se tocó de verdad, verificando salud después.
   Testable: forzar fallo de download/checksum → internet sigue arriba (fail-open), proxy filtrando,
   sin ventana de internet-cero.
6. **Golden rule fail-open (ARCHITECTURE.md §Watchdog) intacto en TODA ruta del fix:** ningún camino
   deja `ProxyEnable=1` apuntando a un proxy que no escucha. No se introduce ninguna ventana
   fail-CLOSED nueva.
7. **Duraciones calibradas, no adivinadas:** los tiempos de retry/paciencia salen de una **retención
   de puerto MEDIDA en la test PC** (estado del socket capturado), documentada en este plan, y el
   agente arreglado se **valida en un repro real ANTES** de re-publicar el OTA. (Anti-repetición del
   rush de 1.0.28: 15s a ciegas fue justo la causa.)

## Non-goals (explícitos — cerca anti-scope-creep)
- **NO** implementar el backlog de hardening ahora: cierre elegante con drenado de túneles CONNECT,
  endpoint de health por identidad/versión, cooldown de versión fallida, lock atómico, poda
  incondicional de backups, `filter_active` que excluya `updating.flag`, escrituras de whitelist
  atómicas, rework del bind-preflight con semánticas exactas de host. Son PRs de seguimiento; el fix
  mínimo NO depende de ellos.
- **NO** cambiar el mecanismo de entrega/publicación del OTA, el hub, ni el dashboard (más allá de
  re-publicar la versión arreglada).
- **NO** cambiar el modelo de lock de instancia única (puerto = lock) ni el `exit(0)` del caso
  hermano-legítimo (logon-herd).
- **NO** tocar identidad/secretos/enrolamiento.
- **NO** es un rework de graceful-shutdown (eso es el hardening "acortar la retención"; el fix mínimo
  es "tener paciencia suficiente para superar la retención").

## Contracts & ADR-locked areas touched
- **`ARCHITECTURE.md` §Watchdog — golden rule fail-open** ("PRIMERO internet normal, LUEGO reinicia
  el proxy"): el fix lo **CONSUME y debe PRESERVARLO**; los fixes #4/#5 devuelven a cumplimiento dos
  violaciones existentes. **No cambia el contrato — lo hace cumplir.**
- **`self-update.js`** (backup/swap/restart/health/rollback, lock single-flight + 3 reintentos, nunca
  sobrescribe identidad/secretos): CONSUME; el fix ajusta la paciencia del health check + el orden
  del catch, manteniendo la forma del contrato.
- **No hay `docs/adr/`** ni lista do-not-touch-without-ADR en el repo. **No se requiere conversación
  de ADR** — no se altera una decisión bloqueada; se ENFUERZA el fail-open, no se cambia.

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR.** Es **superficie de riesgo**: toca la ruta de self-update que, mal hecha, dejó
un terminal sin filtrar 44 min (y las variantes fail-CLOSED dejan sin internet). Multi-archivo
(`proxy-server.js`, `CheckPort.ps1`, `self-update.js`) + calibración empírica + validación en repro
en vivo + re-publicación del OTA. Por la regla de bias-to-escalate (cualquier superficie de riesgo →
FULL-ORCHESTRATOR), amerita el gate completo: **reviewer separado + el repro de la test PC como gate
E2E antes de re-publicar.**

## Open questions — resueltas (Felix, 2026-07-24)
1. **[ABIERTA — se resuelve en build]** Retención de puerto medida + mecanismo exacto del SO
   (TIME_WAIT vs `SO_EXCLUSIVEADDRUSE`, y si depende de túneles CONNECT vivos) — se resuelve con el
   repro en la test PC, que es **el primer paso de build IN-SCOPE** (calibra AC7).
2. **[RESUELTA]** Política de whitelist vacío (AC4): **vacío = SIEMPRE last-known-good** — un
   whitelist vacío nunca es intencional; si la lectura falla/queda vacía → preservar el anterior o no
   reportar "sano". (No existe el caso block-all-por-whitelist-vacío.)
3. **[RESUELTA]** Sale como **1.0.29** (supersede 1.0.28). Tras validar el repro: re-publicar OTA
   1.0.29 + refrescar `/descargar`, **y retirar/superseder la fila OTA 1.0.28** para que ninguna
   máquina levante la versión que loopea.
