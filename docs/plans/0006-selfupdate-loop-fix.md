# Plan 0006 — Fix del loop de self-update (P0 del OTA 1.0.28)

Estado: **LOCKED — aprobado por Felix 2026-07-24.** Gear confirmado: **FULL-ORCHESTRATOR**. Este doc
es el contrato; toda fase posterior se mide contra él y cualquier drift es STOP-and-report. Siguiente
fase: build orquestado (reviewer separado + repro de la test PC como gate E2E), empezando por el repro
empírico que calibra AC7. Diagnóstico + cross-review Fable↔Codex (2 rondas) en el post-mortem.

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
