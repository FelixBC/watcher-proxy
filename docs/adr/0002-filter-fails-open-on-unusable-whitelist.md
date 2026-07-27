# ADR 0002 — El filtro hace fail-open ante un whitelist inservible (nunca bloquea todo)

- **Estado:** Aceptado (2026-07-26, Felix).
- **Contexto de la decisión:** plan 0008 (piso fail-open del whitelist + last-known-good en disco),
  Capa 1 del plan de defensa "internet siempre".
- Segundo ADR del repo; sigue la forma del 0001 (Contexto / Decisión / Consecuencias / Reversibilidad).

## Contexto

La regla de oro del repo (`CLAUDE.md`, `ARCHITECTURE.md` §Watchdog) dice explícitamente: **"Fail OPEN,
never fail CLOSED... the filter is allowed to fail open (normal internet); the connection itself must
never fail closed."** Felix reafirmó y priorizó esto: **catástrofe = quedarse SIN internet; el filtro es
secundario.** Una banca que no puede llegar a ningún sitio no puede trabajar — eso es tan malo como no
tener internet.

Pero `proxy-server.js` no honraba esa regla para un caso concreto: si `whitelist.txt` quedaba
**inservible** (0 entradas por una escritura interrumpida en un apagón, o un push malo del hub, o el
archivo ausente), `loadWhitelist` cargaba 0 dominios y el proxy **bloqueaba TODO** (404 a cada sitio) —
over-block. El proxy estaba "vivo" (puerto abierto), así que el watchdog lo mantenía como `PE=1`, y el
resultado era una banca sin poder llegar a nada. Es la catástrofe, por la vía del filtro.

## Decisión

El filtro **hace fail-open ante un whitelist inservible**, con esta precedencia (nunca over-block):

1. **whitelist.txt live usable** (≥1 entrada) → filtra normal. Se persiste como last-known-good en disco.
2. **live inservible, pero hay un bueno en MEMORIA** → se conserva el de memoria (last-known-good runtime).
3. **live inservible, sin bueno en memoria** (ej. arranque en frío) → se carga el **last-known-good del
   disco** (`WatcherBrain/whitelist-lastgood.txt`) y se reanuda el filtrado.
4. **nada usable en ningún lado** → **FAIL OPEN: el proxy deja pasar TODO** (internet garantizado, sin
   filtro). El filtro se reanuda solo cuando vuelve un whitelist válido.

Condiciones (todas obligatorias):
- **El fail-open es VÍA el proxy** (Fork A, resuelto por Felix): el proxy sigue en el camino y deja pasar
  todo — **no** se hace bypass a internet normal. Así el filtrado se reanuda al instante cuando vuelve un
  whitelist bueno (sin tocar el registro) y la telemetría (visitas/logs) sigue.
- **Cubre HTTP y HTTPS** (request y CONNECT — ambos gatean por `isWhitelisted`).
- **Observable:** entrar en fail-open escribe un evento (`filter-failopen`) en el event log, para que la
  flota vea que una máquina quedó sin filtrar.
- **El last-known-good de disco es estado por-máquina protegido** (`PROTECTED_RELATIVE_PATHS`), escrito
  Hidden+System-safe + write-then-truncate.

## Consecuencias

**Positivas**
- La catástrofe "over-block / sin poder trabajar" desaparece a nivel de máquina, **por construcción**: un
  whitelist inservible nunca vuelve a bloquear todo.
- Cubre el escenario fleet-wide de un push malo del hub: el proxy cae al last-known-good (disco) y sigue
  filtrando; y si además hay apagón + cold boot, el disco es de dónde cae.
- Alinea el código con la regla de oro ya escrita ("el filtro puede fail-open").

**Costos / lo que asumimos**
- Un whitelist inservible sin respaldo deja la máquina **temporalmente sin filtrar** (allow-all). Es un
  estado aceptado (internet > filtro), acotado (se recupera solo al volver un whitelist válido) y
  reportado (evento). No es la política ideal, pero la banca sigue trabajando.
- Un archivo de estado más por-máquina (`whitelist-lastgood.txt`), con su costo de escritura (barato,
  write-if-changed).

**Reversibilidad**
- Si se quisiera volver al comportamiento "bloquear ante whitelist vacío", es un cambio local en
  `loadWhitelist`/`isWhitelisted`. Pero contradiría la prioridad LOCKED de Felix; no se prevé revertir.

## Relación con otros planes
- Es la **Capa 1** (agente resiliente) del plan de defensa. Las Capas 2–4 (rollout por anillos + auto-halt,
  validación al publicar en el hub) son planes aparte y reducen la *probabilidad* de un push malo; esta
  capa hace que, si igual pasa, **no sea catástrofe**.
- Ortogonal a 0007 (blue-green) y su ADR 0001.
