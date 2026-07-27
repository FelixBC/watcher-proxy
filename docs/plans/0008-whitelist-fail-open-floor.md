# Plan 0008 — Piso fail-open del whitelist + last-known-good en disco

Estado: **CONSTRUIDO + VERIFICADO (2026-07-26).** Reviewer separado (green-loop) lo despejó sin fixes
obligatorios; E2E en HW real (test PC 10.0.0.72, no-destructivo) 7/7: filtra+persiste sidecar / disco
last-known-good tras restart / fail-open sin sidecar. ADR 0002 escrito. Forks A/B/C resueltos por Felix.
Falta solo: commit/release (git de Felix). Capa 1 del plan de defensa "internet siempre"
(espejo alineado 2026-07-26). Ortogonal a 0007 (blue-green): es una capa de seguridad del agente,
encima. Forks A/B/C resueltos por Felix; A aplica acá (proxy deja pasar todo). B/C son de las capas
2–4 (anillos/hub), fuera de alcance de este plan.

## Problem (una frase)
Hoy, si el whitelist de una banca queda **inservible** (vacío/corrupto/ausente — por una escritura
interrumpida en un apagón, o un push malo del hub), `proxy-server.js` carga 0 dominios y **bloquea
TODO** (404 a cada sitio) → la banca no llega a ningún lado y no puede trabajar; por la prioridad
LOCKED *"catástrofe = sin internet; el filtro es secundario"*, el proxy debe en cambio **fail-open
(dejar pasar todo)** para que internet nunca se pierda, y **conservar el último whitelist bueno a
través de reinicios/apagones** para que el filtro se recupere solo.

## Contexto / relación con lo ya hecho
Ya está a medias (durability fix 2026-07-26): `loadWhitelist` (`proxy-server.js`) tiene
**last-known-good en MEMORIA** (parsea a sets frescos y conserva el bueno si el nuevo viene vacío),
y `whitelist-merge.js`/`writeInPlace` escribe **write-then-truncate** (nunca deja el archivo
momentáneamente vacío). **Falta**: (a) el **PISO fail-open** — hoy, sin bueno en memoria (ej. cold
boot), `createDefaultWhitelist` deja un whitelist casi-vacío → bloquea todo; debe **dejar pasar
todo**; (b) **persistir el último bueno en DISCO**, para que sobreviva al apagón (la memoria se pierde
en un cold boot; el sleep/hibernación la preservan).

## Acceptance criteria (numeradas, testables — gate = repro en la test PC)
1. **Piso fail-open (el titular):** si el whitelist está inservible (0 entradas, ilegible, o el archivo
   no existe) **y no hay** last-known-good disponible (ni en memoria ni en disco), el proxy **DEJA PASAR
   todo** — un sitio NO-whitelisteado carga (pasa), **no** da 404. NUNCA bloquea todo. Testable: con
   `whitelist.txt` vacío y sin sidecar de respaldo, un `GET` a un sitio no-whitelisteado a través del
   proxy pasa (200/tunel), no 404; y aplica **tanto a HTTP (request) como a HTTPS (CONNECT)**.
2. **Last-known-good en MEMORIA (ya hecho — preservar, no regresar):** en runtime, si una re-lectura del
   whitelist viene vacía/ilegible pero hay uno bueno cargado, se mantiene el bueno. Testable: cargar
   bueno → luego vacío → un no-whitelisteado sigue dando 404 (filtra con el bueno), un whitelisteado pasa.
3. **Last-known-good en DISCO (nuevo):** cada vez que se carga un whitelist válido, se persiste una copia
   de respaldo en disco (sidecar). En un **cold start** (reboot/apagón) donde `whitelist.txt` quedó
   vacío/corrupto, el proxy carga del sidecar y **reanuda el filtrado** (ni fail-open ni over-block).
   Testable: sembrar un sidecar bueno, vaciar `whitelist.txt`, **reiniciar el proceso** → filtra con el
   sidecar (no-whitelisteado 404, whitelisteado pasa).
4. **Orden de precedencia, sin over-block en ningún nivel:** whitelist live válido → sidecar en disco →
   fail-open allow-all. Testable: los tres estados producen filtrar / filtrar-con-respaldo / dejar-pasar
   respectivamente; **ninguno** produce bloquear-todo.
5. **Fail-open ES vía el proxy (Fork A, resuelto):** el proxy se queda en el camino y deja pasar todo —
   **NO** cambia Windows a internet normal (no bypass). Así, cuando vuelve un whitelist válido el filtro
   se reanuda al instante sin tocar el registro, y la telemetría (visitas/logs) sigue. Testable: durante
   fail-open, el proxy sigue siendo quien sirve (el puerto sigue bindeado, `ProxyEnable=1` apunta a él),
   y al restaurar un whitelist bueno vuelve a filtrar sin intervención del watchdog.
6. **Visibilidad en telemetría:** entrar en fail-open (allow-all) queda **observable** — se registra un
   evento y el poll reporta el estado del filtro, para que la flota vea que una máquina está sin filtrar.
   Testable: al entrar en fail-open se escribe un evento en el log; el poll incluye el estado.
7. **Golden rule intacto / sin regresión:** no cambia el fail-open existente para un proxy MUERTO (sigue
   yendo a internet normal), ni debilita el filtrado cuando el whitelist ES válido. Testable: whitelist
   válido → filtra igual que hoy; proxy muerto → internet normal igual que hoy.

## Non-goals (explícitos)
- **NO** el rollout por anillos / canary (Capa 2 — plan aparte). Fork B/C viven ahí.
- **NO** la validación del lado del hub al publicar (Capa 3/4 — plan aparte).
- **NO** el health-check funcional del update antes del cutover (pieza hermana de Capa 1, pero es del
  camino del UPDATE, no del load del whitelist → plan aparte).
- **NO** cambiar la lógica de merge (`whitelist-merge.js`) más allá de lo ya hecho.
- **NO** un "piso mínimo de N entradas" (heurística anti-reducción) — eso es validación de hub (Capa 3);
  acá 0 entradas = inservible y punto.
- **NO** tocar identidad/secretos/enrolamiento, OTA, hub, ni el contrato cross-repo.
- **NO** cambiar cómo filtra un whitelist VÁLIDO (sin nueva semántica de filtrado).

## Contracts & ADR-locked areas touched
- **Golden rule (`ARCHITECTURE.md` §Watchdog / `CLAUDE.md`):** CONSUME + **IMPLEMENTA**. El golden rule
  ya dice *"the filter is allowed to fail open (normal internet)"* — este plan lo cumple para el caso
  "whitelist inservible", que hoy se resuelve mal (over-block). No cambia el contrato; lo honra. **Pero
  introduce un mecanismo nuevo de fail-open (el proxy en modo allow-all, en vez de apagar el proxy)** →
  se **propone capturarlo en `docs/adr/0002-filter-fails-open-on-unusable-whitelist.md`** (2º ADR del
  repo), en el mismo cambio. No es bloqueante (alineado con el golden rule), pero es una decisión de
  diseño notable que merece quedar escrita.
- **`proxy-server.js` (camino core del proxy — superficie de riesgo):** CAMBIA — `loadWhitelist` gana la
  carga del sidecar + el modo fail-open; `isWhitelisted` / el request handler / el `connect` handler
  respetan el modo fail-open (allow-all). `createDefaultWhitelist` deja de establecer un estado que
  bloquea-todo.
- **Sidecar `WatcherBrain/whitelist-lastgood.txt` (NUEVO archivo de estado por-máquina):** debe entrar a
  `PROTECTED_RELATIVE_PATHS` (self-update.js) para que el OTA no lo pise, y escribirse Hidden+System-safe
  + write-then-truncate (la durabilidad que ya aplicamos al resto).

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR (liviano).** Superficie de riesgo: es el **modo de falla del filtro**, el camino
core del proxy, en terminales de lotería. Por bias-to-escalate amerita reviewer separado + gate E2E en
la test PC (verificar que fail-open realmente da internet en HW, y que el sidecar reanuda el filtro tras
reboot). Es contenido (1 archivo core + 1 sidecar + ADR), así que el orchestrator será liviano; Felix
puede bajarlo a SINGLE-CONCERN + reviewer + E2E si lo prefiere. El E2E es lo no-negociable.

## Open questions (resueltas en el draft, para confirmar)
1. **[propuesta] Sidecar + cuándo escribir:** `WatcherBrain/whitelist-lastgood.txt`, actualizado
   (write-then-truncate, +h+s-safe) cuando se carga un whitelist válido **y difiere** del sidecar actual
   (evita churn). Protegido del OTA.
2. **[propuesta] Definición de "inservible":** 0 entradas parseadas, error de parseo, o archivo ausente.
   Un parseo con ≥1 entrada = válido y filtra (el piso mínimo de N es de la Capa hub).
3. **[propuesta] Alcance de fail-open:** cubre HTTP (request) **y** HTTPS (CONNECT) — ambos dejan pasar.
4. **[confirmar] Interacción con un push malo del hub + cold boot:** push vacío → live vacío → el proxy
   usa el sidecar (sigue filtrando); si además hay cold boot, el sidecar (disco) es de dónde cae → filtra.
   Así el sidecar es lo que cubre el escenario fleet-wide del push malo. ¿De acuerdo con este mecanismo?
