# Plan 0019 (watcher-proxy) — Ubicación: "Location apagado" por FALLOS CONFIRMADOS, no por reloj

Estado: **DEFINIDO — lock pendiente de Felix (2026-08-06).** CORRIGE el disparador de la alerta del plan 0018.
Cross-repo: agente (watcher-proxy) → VERSION + OTA; ajusta la lógica de alerta del hub (watcher-fleet).
Origen: un tune fallido (v1.0.46, revertido) que Codex frenó antes de publicar — ver "Qué pasó".

## Problem (una frase)
La alerta "Location apagado" del 0018 se dispara por una señal de **reloj** (el fix de Windows envejeció más
que un TTL), y el reloj se rompe cruzando un **sleep/offline**: al despertar, un **único** probe fallido con
Location REALMENTE encendido produce una **alerta falsa** — y además la alerta **no sale nunca** si el servicio
geo-IP no contesta (falso negativo).

## Qué pasó (contexto)
- Para acelerar la detección de 2h→~35min bajé dos constantes acopladas (`LOCATION_ATTACH_TTL_MS` 2h→35min,
  `LOCATION_MAX_AGE_MS` 55→12min) con una "invariante" `TTL > 2×refresh`. **v1.0.46, revertido.**
- Codex (a pedido de Felix, cross-review pre-publish) → veredicto **ITERATE / bloqueador**. Repo, `VERSION` y el
  bundle de `fleet/public` de vuelta en **1.0.45** (estado de prod).
- La invariante solo protege con **polling ininterrumpido**; el sleep/offline/clock-forward **consume el TTL sin
  dar 2 muestras**, así que un solo fallo transitorio basta.

## Hallazgos de Codex (triados) — lo que este plan resuelve
1. **ALTO (bloqueador, PRE-EXISTENTE, mi tune lo amplificaba):** falso positivo sleep/resume. Fix a las 08:00 →
   duerme > TTL → al despertar el poll perdido → fix vencido → el 1er probe de Windows falla (broker/WiFi
   calentando) → en el MISMO poll manda geo-IP → hub ve `prevSource==="windows"` → **alerta falsa**. Con 35min
   sería casi cada mañana; con 2h es el mismo bug, más raro (por eso no se ha visto en prod).
2. **MEDIO (pre-existente):** con off, el no-fix nunca refresca el mtime → `refreshLocationIfDue` queda "due"
   cada poll → un spawn de PowerShell (timeout 15s) **cada ~2min para siempre** (~720/día).
3. **MEDIO (pre-existente, FALSO NEGATIVO):** la alerta vive dentro de `else if (hasGeo)` (hub route.ts:232). Si
   los 2 proveedores geo-IP fallan, `hasGeo` es false → **la rama no corre → sin alerta** (y `geoip-attempt.txt`
   suprime 6h). Rate-limit real (429) ya observado en pruebas.
4. **BAJO:** comentarios mienten (reintenta cada 2min, no 12) e invariante solo-prosa sin assert.
- Codex confirmó: mtime y `at` se mueven juntos en escrituras normales; self-update PROTEGE `location.json`
  (self-update.js:171); ningún otro lector asume 55min/2h; el guard `prevSource==="windows"` protege el día-1 y
  las máquinas que nunca tuvieron fix, pero **NO** el sleep/resume.

## Diseño elegido (mis recs — a confirmar por Felix)
Dejar de inferir "off" del **tiempo** y confirmarlo con **fallos observados**:
- **AGENTE — contador de no-fix consecutivos, persistido.** `refreshLocationIfDue`: éxito → contador **0**;
  no-fix/probe-failed → **+1**. El poll trata Location como **off solo cuando `consecutiveNoFix ≥ N`** (rec **N=3**)
  — N pollings **despiertos** fallando de verdad, no reloj. Mientras `<N`, sigue mandando el último fix de Windows
  (aunque esté algo viejo) → **cero alerta falsa en el calentamiento**. Inmune al sleep: el 1er fallo tras
  despertar = 1/N.
- **AGENTE — señal explícita `location_off`** en el poll body cuando el contador confirma off, **independiente de
  geo-IP**. geo-IP sigue siendo solo "el dónde aproximado".
- **AGENTE — back-off del probe** una vez confirmado off (~cada 12min en vez de cada poll) → mata el finding 2.
- **AGENTE — solo reclama off si tuvo ≥2 fixes de Windows** (Felix, 2026-08-06: ≥2, no ≥1 — un fix suelto de
  fluke no arma). Marker set-once (`location-armed.flag`). Un desktop que nunca triangula (no-fix ambiental)
  arranca directo en geo-IP "aproximada", **sin** reclamar off.
- **HUB — la alerta la dispara `location_off`, no la transición de fuente.** Sale aunque geo-IP no llegue.
  Conserva el guard `prevSource==="windows"` (estreno + máquinas sin fix). Para agentes **viejos** (sin el campo)
  conserva el comportamiento actual (bug raro tolerado hasta el OTA) — sin regresión, sin nuevo falso positivo.
- **Detección de off genuino** ≈ `MAX_AGE` + `N×poll` (rec `MAX_AGE`→~12min, N=3, poll ~2min) ≈ **~≤20 min**,
  predecible y a prueba de sleep.

## Acceptance criteria (numeradas, testables)
1. **"Off" se confirma por FALLOS, no por reloj.** El agente declara off SOLO tras N (=3) probes consecutivos
   sin fix (contador persistido, reset a 0 en cada fix). Un solo no-fix NO lo declara off. Test (máquina ya
   ARMADA, ≥2 fixes previos): `fix→no-fix→fix` nunca marca off ni manda `location_off`; `fix→no-fix×3` sí.
2. **Inmune a sleep/resume (el bloqueador, repro del finding 1).** Fix a T + salto de reloj > el TTL viejo + 1
   probe no-fix al "despertar" → el poll sigue mandando el último Windows, `location_off` ausente/false, el hub
   **NO** inserta alerta. Test: la secuencia de repro no produce fila en `machine_tamper`.
3. **Detección de off genuino acotada (~≤20 min).** Con Location realmente apagado y la máquina despierta, la
   señal `location_off` (+ geo-IP si contesta) llega en ≤ ~20 min. Test: apagar Location → dentro de ~20 min el
   poll lleva `location_off` y el hub emite 1 alerta.
4. **La alerta NO depende de geo-IP (finding 3).** `location_off:true` **sin** `body.geoip` (proveedores caídos)
   → el hub emite la alerta igual (con el guard de estreno), sin coordenada aproximada. Con geo-IP presente,
   además pinta el círculo de ciudad. Test: ambos casos.
5. **Back-off del probe con off confirmado (finding 2).** Confirmado off, GetLocation deja de correr cada poll y
   pasa a ~cada 12min. Test: tras confirmar off, los spawns caen de ~1/poll a ~1/12min.
6. **Solo reclama off si tuvo ≥2 fixes (caso desktop ambiental + anti-fluke).** Una máquina con <2 fixes
   históricos de Windows NO manda `location_off` ni dispara alerta; arranca en geo-IP "aproximada". Un fix
   suelto de fluke (fixes=1) tampoco arma. Test: máquina con 0-1 fixes → geo-IP sin señal de off; el hub no
   alerta. (Consecuencia aceptada: una banca marginal que solo logra 1 fix en su vida nunca alertará.)
7. **Guard de estreno preservado.** El hub solo alerta si la fuente previa fue un fix real de Windows
   post-despliegue. Test: `last_location` sin `source` (pre-0018) o sin fix previo → primera señal NO alerta.
8. **Retro-compat + rollout.** `/api/agent/poll` solo se amplía (`location_off` aditivo). Agente viejo (1.0.45,
   sin el campo) → 200 y el hub conserva su comportamiento previo para él; agente nuevo → la señal manda. Test:
   poll 1.0.45 → 200 sin cambio de conducta; poll nuevo con `location_off` → alerta por la señal.
9. **Contador/markers persistidos y protegidos.** El estado (contador + "ever-had-fix") vive en un archivo
   (+h/+s aware) añadido a `PROTECTED_RELATIVE_PATHS` (self-update lo preserva, como `location.json`). Test: un
   OTA no borra ni resetea el estado.
10. **Regla de oro + best-effort intactas.** Nada toca `ProxyEnable`/el filtro; probe y geo-IP siguen time-boxed;
    un fallo nunca tumba el poll (responde 200). Test: probe/geo-IP que fallan → poll 200.
11. **Comentarios exactos; la invariante deja de ser prosa (reemplaza finding 4).** Los comentarios describen la
    máquina de estados real (reintento por poll hasta confirmar, back-off después); se elimina la invariante
    `TTL>2×refresh` que ya no aplica.

## Non-goals (explícitos)
- **NO subir la cadencia del poll** (~2min se mantiene).
- **NO distinguir por err code** de GetLocation "apagado" vs "no triangula" (siguen indistinguibles; por eso el
  contador + el guard "ever-had-fix", no el código).
- **NO forzar Location on** (el agente no puede; Nelson lo prende a mano).
- **NO precisión con Location off** — geo-IP sigue grueso (~ciudad). Hereda 0018.
- **NO nueva dependencia externa** — sigue `ipapi.co`/`ipwho.is` (0018), sin tercer proveedor.
- **NO tiempo real / enforcement** (hereda 0005).
- **NO dropear columnas; probablemente NO nueva migración** — `machine_tamper` + `last_location` (jsonb) bastan
  (confirmar al construir; si hace falta una, una por PR y `git ls-tree` cada rama por el próximo número libre).
- **NO cambiar la semántica de distancia precisa** de Windows ni la UI del mapa/badge (heredan 0018 intactas).

## Contracts & ADR-locked areas touched
- **`POST /api/agent/poll` (SUPERFICIE DE RIESGO — única ruta de escritura ~216k/día):** solo se amplía
  (`location_off` aditivo). El cómputo sigue O(1) best-effort.
- **Alerta `machine_tamper` de auditoría anti-evasión (0018 AC6; audit 0005/0008):** cambia el **disparador** (de
  transición de fuente `windows→geoip` a la señal explícita `location_off`), **no** la semántica de la tarjeta
  ni su surfacing (`setting:null` → one-shot serio se conserva). Zona **audit-sensible**: un falso positivo o un
  falso negativo de 6h hunden la credibilidad de la señal — esa es la razón de existir de este plan.
- **`last_location.source` (jsonb) + guard `prevSource==="windows"`:** se conservan (estreno + máquinas sin fix).
- **`self-update.js` `PROTECTED_RELATIVE_PATHS`:** se añade el nuevo archivo de estado del contador.
- **Regla de oro (fail-open, ADR 0002) + ADR 0001:** intactas — esto es ortogonal al filtrado.
- **`VERSION` + OTA.**
- **Dependencia geo-IP (0018):** sin cambios; la alerta deja de depender de ella (ese es el arreglo del finding 3).

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR.** Multi-repo interdependiente (agente: máquina de estados + contador persistido + back-off +
señal; hub: disparador de la alerta + rama sin-geoip + retro-compat) sobre **superficie de riesgo**: la única ruta
de escritura de la flota y la **alerta de auditoría laboral anti-evasión**. Revisor separado + 2ª pasada de Codex
+ gate E2E (repro del sleep como test negativo + off real en la test PC / fixtures del hub).

## Open questions (para SOLVE — cada una con mi recomendación; piden sign-off)
1. **N y cadencia → latencia vs overhead.** → **N=3**, `LOCATION_MAX_AGE_MS`→~**12min**, back-off del probe
   confirmado-off ~**12min** ⇒ detección **~≤20min**. ¿OK, o prefieres otro punto (más rápido = más spawns de
   PowerShell cuando está ON)?
2. **¿Backstop de frescura del fix?** → mantener un **cap suelto (~12h)**: no reafirmar un fix anciano como
   "actual" aunque el contador siga `<N` (p.ej. sleep larguísimo). **No es el decisor**, solo higiene.
3. **Forma de la señal en el contrato.** → **`location_off: boolean`** aditivo (no un enum de fuente). Mínimo y
   claro; el hub lo lee tolerante.
4. **Rollout / agentes viejos.** → el hub conserva la **transición vieja SOLO para agentes sin el campo** (bug
   raro tolerado hasta que el OTA los suba); agentes nuevos → la señal manda. Alternativa: apagar la alerta para
   agentes viejos (falso-negativo unos días). **Rec: conservar** (no introduce regresión).
5. **Dónde persistir el contador.** → **archivo nuevo `location-state.json`** (+h/+s aware, en
   `PROTECTED_RELATIVE_PATHS`), separado del breadcrumb `location-health.txt`. Alternativa: extender el health.

## Build — CONSTRUIDO + verificado (2026-08-06)
Lock aprobado por Felix + 2 decisiones firmadas: **cadencia 12 min (~18 min detección)** y **≥2 fixes para armar**.
Orquestado: RESEARCH (2 agentes read-only, agente+hub) → SOLVE + green-loop-critic (opus) → DECOMPOSE →
IMPLEMENT (orquestador) → VERIFY (revisor opus separado + 2 pasadas Codex). Sin migración de DB.

**Piezas.** Agente (`poll-hub.js`): constantes (`LOCATION_NOFIX_CONFIRM=3`, `LOCATION_BACKOFF_MS=12min`,
`LOCATION_MIN_FIXES_TO_ARM=2`, `LOCATION_FIX_BACKSTOP_MS=12h`), `readLocationState`/`writeLocationState`/
`isLocationArmed`/`armLocation`, `refreshLocationIfDue` reescrita (contador en las ramas de resultado, back-off,
devuelve el estado en-memoria), cuerpo del poll (`attachWindows`/`sendGeoip`/`body.location_off` solo si armado);
`self-update.js` (2 archivos de estado en `PROTECTED_RELATIVE_PATHS`); `.gitignore`; `VERSION`→**1.0.47**; bundle
/descargar→1.0.47. Hub: `poll/route.ts` (`PollBody.location_off`, ramas hasLoc/hasGeo/offConfirmed + fuente
`"off"`, alerta sacada de la rama geo-IP con dispatch nuevo/viejo por presencia del campo, `loc_source` solo
windows/geoip en el sample); `page.tsx` (fuente `"off"` → estado vacío honesto, guard `sourceKnown`);
`machine-actions.ts` (guard de fijar-área extendido a `"off"`).

**Decisiones de build.** N=3 · refresh 12 min · back-off 12 min · backstop 12 h · armar a ≥2 fixes · `location_off`
se manda **solo si armado** (unarmed → el hub usa la transición legacy = puente de OTA) · dedup A2 = fuente
`"off"` conservando la última coord, con la UI reusando el estado vacío existente (cero refactor de los 14 sitios
del panel).

**Revisión — cegueras disjuntas.**
- green-loop-critic (opus): 2 bloqueadores → **arreglados** (always-send-boolean para AC2; contador en
  `refreshLocationIfDue`, no en `noteLocationOutcome`). A2 elegido sobre A1.
- Revisor opus separado: **PASS**, 0 HIGH/MEDIUM; 4 LOW (comentario viejo, prosa ≥1 vs ≥2, reuse de 1.0.46,
  comentario CHECK) → **todos cerrados** (incl. subir a 1.0.47).
- Codex (1ª pasada): **2 nuevos reales arreglados** — #2 hueco de OTA (unarmed manda `location_off:false` y
  desactiva el detector legacy → ahora se OMITE mientras unarmed); #3 write torn (ahora usa el estado en-memoria
  post-probe). #1 (atomicidad) = **PRE-EXISTENTE, diferido** (ver abajo).
- Codex (pasada sobre los ARREGLOS): **SÓLIDOS, sin regresión HIGH/MEDIUM.** Trazó Fix A (los 4 escenarios) y
  Fix B como correctos; confirmó finding 1 PRE-EXISTENTE contra el commit de 0018 `b521da5`. Único item: 2
  comentarios del hub que decían "siempre manda el boolean" → **corregidos** (tras Fix A el unarmed lo omite).

**Verificación.** Agente `node --check` OK (poll-hub + self-update) · hub `tsc --noEmit` 0 · `npm run verify`
**21/21** · lint limpio en los tocados · bundle 1.0.47 (sha en el build). E2E en HW = de Felix (abajo).

**Lo que falta, y es de Felix.** (1) `vercel --prod --yes` (hub) — **sin migración**. (2) OTA:
`publish-agent.mjs` (agente 1.0.47); /descargar ya en 1.0.47. (3) E2E test PC: instalar/OTA → con Location ON
dejar armar (≥2 fixes) → apagar Location → geo-IP + alerta "Location apagado" en ~≤20 min; + repro de sleep como
test negativo (no debe alertar).

## Deferred follow-up (fuera del scope de 0019 — PRE-EXISTENTE)
**Atomicidad insert-alerta ↔ update-fuente (Codex finding 1, ALTO, diferido por Felix 2026-08-06).** El
`machine_tamper` insert (LOG-ONLY) y el `machines.update` que voltea `last_location.source` NO son atómicos;
el dedup es la transición de fuente. En un fallo transitorio de DB entre ambos: si el insert falla y el update
pasa → el episodio no alerta (falso negativo); si el insert pasa y el update falla (su error hoy se ignora) →
alerta duplicada. Dos polls solapados/replay podrían ambos insertar (el índice único no protege: `setting`
NULL son distintos en Postgres y `at=now` cambia). **Ya existía en 0018** (misma estructura insert+update);
0019 no lo introduce ni lo empeora. **Fix real = una operación transaccional (RPC de Postgres)** que voltee la
fuente e inserte la alerta en una sola transacción, o una identidad de episodio con unicidad retry-safe. No
toca el filtro ni la regla de oro (el insert es best-effort/no-500). Abrir plan propio si el ruido lo amerita.

## Verificación de estado al definir
Repo en **1.0.45** (agente, `VERSION`, bundle de `fleet/public`), consistente con prod. Nada construido para 0019.
