# Plan 0007 — OTA sin hueco de filtro ("blue-green con hogar fijo")

Estado: **LOCKED v1 — aprobado por Felix 2026-07-25.** La reversión arquitectónica de "puerto=lock"
está capturada en **ADR `docs/adr/0001-relax-port-lock-during-update-cutover.md`** (el primer ADR del
repo). Build **SECUENCIAL**: arranca DESPUÉS de verificar + desplegar 0006 (primero frenar el loop de
44 min) → **PARKED** hasta entonces. Diseño completo dibujado en el artefacto de blue-green (privado).
Hardening #1; COMPLEMENTA a 0006 y puede reemplazar su health-check paciente en el happy path
(coexisten — la ruta degrade mismo-puerto lo sigue necesitando).

## Problem (una frase)
Aun con el fix de 0006 (que frena el loop), un update OTA exitoso deja el filtro **apagado ~60–90s**
en CADA máquina mientras el proxy nuevo arranca en frío (fail-open: internet sí, pero filtro no — un
hueco en lo único que el producto hace), porque el diseño **mata el proxy viejo antes** de que el nuevo
escuche; queremos que el filtro **nunca** tenga hueco durante un update.

## Contexto / relación con 0006
0006 acepta el hueco como fail-open seguro. 0007 lo lleva a **cero**: en vez de matar-y-re-bindear el
mismo puerto (con hueco), **levanta el nuevo en un puerto temporal B mientras el viejo sigue filtrando
en el hogar A (:49732)**, cambia Windows a B **solo cuando B ya escucha**, mata A, **re-arranca en A**
(que ahora quedó libre) y vuelve al **hogar fijo** — sin drift. Es el patrón blue-green/zero-downtime
estándar, adaptado a que el "puerto = candado" de este repo.

## Acceptance criteria (numeradas, testables — gate = repro real en la test PC)
1. **Filtro sin hueco (E2E, el titular):** durante un update N→N+1 en la test PC, un sitio
   NO-whitelisteado (ej. supercarros) queda **BLOQUEADO en todo instante** — muestreado repetidamente
   (cada ~2s) desde antes del update, durante el cold-start, en el cutover y después. **No existe una
   ventana sin filtro** mayor a un umbral sub-segundo (el instante del flip de registro). Contraste
   medible vs. el hueco de ~60–90s de 0006.
2. **Vuelve al hogar fijo (sin drift):** tras cualquier update exitoso, el proxy escucha en el puerto
   **hogar canónico (:49732)**, `proxy-port.txt` = hogar, y **ningún** proxy queda en el puerto andamio
   B (liberado). Observable: post-update `readChosenPort()`==hogar, proxy en hogar, nada en B.
3. **Golden rule en todo instante:** en NINGÚN momento del update Windows (`ProxyServer`/`ProxyEnable=1`)
   apunta a un puerto sin nadie escuchando. Testable: muestreando durante todo el update, cada vez que
   `ProxyEnable=1` hay un proceso vivo escuchando en el puerto apuntado. La red fail-open de 0006 sigue
   intacta si todo muere.
4. **Degrade seguro si no hay puerto andamio libre:** si todos los puertos del pool (excepto el hogar)
   están ocupados, el update **degrada al kill-and-rebind del mismo puerto** (la ruta de 0006) — sigue
   convergiendo, sigue fail-open. Testable: ocupar todos los slots del pool en la test PC → disparar
   update → usa la ruta mismo-puerto, converge, sin loop.
5. **Instancia única preservada fuera del cutover:** en estado estable hay **exactamente un** proxy
   escuchando en el hogar. El ÚNICO momento con dos proxies vivos es la ventana acotada del cutover,
   **gateada por `updating.flag`** (con el stale-guard de 0006) para que ninguna capa del watchdog
   arranque un tercero. Testable: post-update exactamente un proceso en el hogar; durante el cutover, a
   lo sumo los dos intencionales.
6. **Firewall del puerto nuevo verificado en HW:** bindear un puerto del pool en la test PC **no**
   dispara un bloqueo/prompt de Defender Firewall que rompa la accesibilidad del proxy nuevo (el
   tráfico cliente es loopback 127.0.0.1). Si por alguna razón B no fuera accesible, el health de B
   falla → **no se hace cutover** → el viejo A sigue filtrando (safe-by-construction). Medido en HW
   antes de shippear.
7. **Duraciones MEDIDAS, no adivinadas:** la latencia del **segundo arranque (volver al hogar)** — la
   hipótesis de que es rápido porque Defender ya escaneó los archivos en el primer arranque — se **mide
   en la test PC** y se documenta aquí. El cutover de vuelta es gap-free **independientemente** de esa
   duración (B filtra hasta que A escuche); la medición decide si "volver al hogar" es barato o si hay
   que reconsiderar (ej. ping-pong entre 2 puertos fijos).

## Non-goals (explícitos)
- **NO** un balanceador multi-puerto ni múltiples proxies en estado estable: exactamente uno vivo en el
  hogar; el andamio es transitorio y acotado al cutover.
- **NO** búsqueda de puertos random: pool chico y fijo de puertos obscuros elegido **en install** (como
  hoy hace `proxy-port.js`), se toma el primer libre ≠ hogar.
- **NO** eliminar la ruta mismo-puerto: se mantiene como el **degrade** garantizado (AC4).
- **NO** tocar identidad/secretos/enrolamiento.
- **NO** cambiar entrega/publicación OTA, hub, ni dashboard (el puerto local es indiferente al contrato
  cross-repo con watcher-fleet).
- **NO** necesariamente eliminar el health-check paciente de 0006 en este PR — la ruta degrade lo sigue
  necesitando; si se retira, es una decisión aparte (open question 1).

## Contracts & ADR-locked areas touched
- **✅ DECISIÓN ARQUITECTÓNICA CAPTURADA — revierte un non-goal de 0006.** El plan 0006 marcó
  explícitamente *"NO cambiar el modelo de lock de instancia única (puerto = lock)"*. Este plan lo
  cambia a propósito: durante el cutover hay DOS proxies vivos (en A y B). Felix firmó la reversión
  (2026-07-25); la decisión, sus condiciones (gateado por `updating.flag`, instancia única fuera del
  cutover, hogar fijo, golden rule en cada instante, degrade al mismo-puerto) y sus consecuencias están
  en **`docs/adr/0001-relax-port-lock-during-update-cutover.md`** — el primer ADR del repo.
- **`ARCHITECTURE.md` §Watchdog golden rule fail-open:** CONSUME y **PRESERVA** (AC1/AC3). No cambia el
  contrato — lo mantiene bajo un mecanismo nuevo.
- **`proxy-port.js` (fuente única del puerto):** CAMBIA su semántica — `proxy-port.txt` pasa de
  "escrito en install + al bindear" a **mutable en runtime durante el cutover**. Los ~5 consumidores
  (`CheckPort.*`, `WatchdogLoop.ps1`, `CheckAndStartProxy.ps1`, `SetProxyByAvailability.ps1`,
  `self-update.js waitForHealthy`) deben coincidir en el puerto en el instante del cambio. **Touchpoint
  crítico:** `proxy-server.js:495` hace `writeChosenPort(CONFIG.PORT)` al escuchar — el proxy nuevo en B
  NO debe reescribir `proxy-port.txt`=B antes del cutover, o los consumidores se adelantan. (Mecanismo
  exacto = SOLVE; el AC3 lo acota.)
- **Cross-repo con watcher-fleet (poll/OTA):** CONSUME, sin cambio de shape.

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR.** Superficie de riesgo (ruta self-update + watchdog), multi-archivo, calibración
empírica (AC6/AC7), validación en repro en vivo, **y revierte un non-goal arquitectónico**. Por
bias-to-escalate, amerita el gate completo: reviewer separado + cross-review Codex + repro de la test PC
como gate E2E antes de shippear.

## Open questions
1. **[RESUELTA — Felix 2026-07-25]** Blue-green **COEXISTE** con el patient-health-check de 0006 (no lo
   reemplaza en este PR): la ruta degrade mismo-puerto lo sigue necesitando; blue-green es el happy path.
2. **[RESUELTA — Felix 2026-07-25]** La reversión "puerto=lock" se captura en el **primer ADR del repo:
   `docs/adr/0001-relax-port-lock-during-update-cutover.md`**.
3. **[abierta — se cierra en build]** Latencia del segundo arranque + comportamiento del firewall del
   puerto nuevo, MEDIDOS en la test PC (AC6/AC7).
4. **[RESUELTA — build 2026-07-25]** Pool = los **3** puertos ya existentes de `proxy-port.js`
   ([49732, 53187, 61045]): hogar + 2 andamios posibles. Atomicidad del cutover: el **registro
   `ProxyServer` es la fuente de verdad del puerto vivo** (no `proxy-port.txt`, que se queda = hogar);
   self-update lo escribe siempre DESPUÉS de que el puerto escuche, y el watchdog aplica el golden-rule
   **reactivamente** contra ese puerto durante el flag → ningún tick lee un estado inconsistente. Detalle
   en ADR 0001 §Actualización.
5. **[RESUELTA — Felix 2026-07-25]** Build **SECUENCIAL**: arranca tras verificar + desplegar 0006. 0007
   PARKED hasta entonces.
