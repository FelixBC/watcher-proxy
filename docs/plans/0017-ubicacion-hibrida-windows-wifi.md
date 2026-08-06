# Plan 0017 (watcher-proxy) — Ubicación híbrida: Windows Location + respaldo por huella Wi-Fi

Estado: **DEFINIDO — lock pendiente de Felix (2026-08-06).**
Cross-repo: el origen (fuente de ubicación) es el AGENTE (watcher-proxy) → VERSION bump + OTA; **extiende** el
motor de auditoría del hub (watcher-fleet plan 0005 "¿trabajó desde su puesto?" + plan 0008 "área por
recurrencia"). Un solo documento, anclado en el agente, que especifica ambos lados — mismo precedente que el
plan 0013 (señal de impresión: el agente produce la señal, el hub toma un campo aditivo).

## Problem (una frase)
El detector de "trabajó fuera de su puesto" (plan 0005) está construido y desplegado pero **en ayunas**: el
agente nunca conseguía ubicación (Windows Location da `Denied` a un servicio headless hasta que un humano
prende el toggle "Location services"), así que `out_of_area` nunca dispara, el mapa queda vacío, y una banca
que se lleva el **laptop** a otro sitio a vender **no se detecta** — que es justo lo que la auditoría existe
para cazar.

## Contexto verificado (test PC, 2026-08-06)
- **Windows Location SÍ funciona como SYSTEM** (fix real ~99 m, `19.463,-70.689`, **sobrevive reboot**) — pero
  solo tras prender **a mano** el toggle "Location services". La escritura de registro del guard NO lo
  reproduce: el toggle refresca el *broker* de permisos, cosa que `Value=Allow` crudo no. (El registro se ve
  IDÉNTICO prendido vs. apagado.)
- **El agente SÍ puede escanear antenas Wi-Fi/BSSID como SYSTEM sin permiso** (21 APs vía `netsh wlan show
  networks mode=bssid`, sin denegación) → fuente automática que **no** depende del toggle.
- **Contrato actual** (verificado en código): el agente manda `body.location={lat,lng,acc,at}`
  (`poll-hub.js:refreshLocationIfDue` → `location.json`, ~horaria). El hub (`api/agent/poll/route.ts` L193-212)
  computa distancia vs `designated_area`+`area_radius_m` (200 m) → `locOut` (-1 sin fix / 0 dentro / 1 fuera) →
  `bump_location` + fila en `machine_sample`. El área se propone del clúster dominante (`lib/audit/location-
  cluster.ts:proposeArea`) y **un humano la confirma con 1 clic** (plan 0008). El mapa es OpenFreeMap **sin
  llave** (`machines/[id]/location-map.tsx`).

## Diseño elegido (por Felix) — prioridad, NO competencia
- **Windows Location = PRINCIPAL.** Cuando da fix (location prendida) → coords → mapa + `out_of_area` por
  **distancia** (como hoy, sin regresión). Es la fuente autoritativa cuando está presente.
- **Huella Wi-Fi = RESPALDO AUTOMÁTICO.** Cuando NO hay fix de Windows (location apagada), el agente reporta la
  **huella** de antenas visibles; el hub la compara contra la **huella de referencia del puesto**:
  misma → en el puesto; cambió → fuera del puesto (alerta). Detecta **movimiento**, sin coords ni API, **$0**.
- **No chocan:** nunca deciden a la vez — con location prendida manda Windows (coords + distancia); el Wi-Fi
  solo entra cuando Windows no da fix. (Cruzar ambos para más confianza = follow-up, no v1.)
- **Todo GRATIS:** reusa el mapa existente. El pin exacto con location-off (resolver huella→coords por API de
  geolocalización) queda **DIFERIDO** (solo si Nelson lo pide).

## Acceptance criteria (numeradas, testables)
1. **Windows Location sigue siendo principal, sin regresión.** Con el toggle prendido, el agente reporta
   `body.location` como hoy y el hub computa distancia vs área. Test: poll con `location`+`designated_area` →
   `locOut` 0/1 por distancia, idéntico al comportamiento actual.
2. **El agente reporta una huella Wi-Fi ~horaria (aditiva al poll):** un conjunto de BSSIDs (+ señal) escaneado
   como SYSTEM, misma cadencia que la ubicación. Test: en la test PC (21 APs) el poll incluye el campo de
   huella; un agente viejo que lo omita sigue dando 200.
3. **Respaldo por huella cuando NO hay fix de Windows.** Sin `body.location` pero con huella + huella de
   referencia del puesto, el hub decide en-el-puesto/fuera por **solape de conjuntos** y alimenta `out_of_area`.
   Test: poll SIN `location` + huella = referencia → "en el puesto"; huella distinta → "fuera del puesto".
4. **La huella de referencia del puesto se establece como el área** (precedente 0005 crit 16 / 0008): propuesta
   desde las huellas más frecuentes en horario laboral + confirmación humana; una huella suelta no la mueve.
   Test: 8 huellas iguales + 1 rara → propone la de las 8, la rara no la mueve. *(Ubicación de la comparación:
   ver Open Q1.)*
5. **El hub distingue y ETIQUETA qué método está activo** (plan 0005 crit 8/12, honesto): cada muestra/estado
   de ubicación indica si vino de **Windows Location** (preciso, con distancia) o de la **huella Wi-Fi**
   (aproximado, sin distancia). Test: fixture con cada fuente → etiqueta correcta; una fila de huella NUNCA se
   presenta con una "distancia".
6. **Disclaimer + badge en el panel Ubicación** (nuevo, pedido por Felix):
   (a) cuando **no se visualiza nada** → un disclaimer explica **por qué** ("location apagada y sin huella de
   referencia aún" / "esperando primera muestra");
   (b) cuando **sí se visualiza** → un badge dice **cuál de los dos métodos** está activo;
   (c) sugiere **encender Location services para seguimiento con distancia exacta** cuando la máquina está en
   modo respaldo. Test: revisión de las claves i18n + los tres estados renderizados (nada / Windows / Wi-Fi).
7. **El guard deja de ENMASCARAR el "off".** `HardenLocation` hoy re-escribe `Allow` al ver `Deny`, lo que
   puede hacer que la UI diga "on" mientras la ubicación está **muerta** (el registro no restaura la función).
   El apagado del toggle debe quedar **visible + alertado** (tamper), no tapado. Test: con location apagada por
   el usuario, el estado reportado NO dice "on/clean" y se emite tamper. *(Ajuste exacto: ver Open Q3.)*
8. **Regla de oro intacta.** Nada toca `ProxyEnable/ProxyServer`/el filtrado. Huella y ubicación son
   best-effort: nunca fallan un poll. Test: huella/ubicación que fallan → el poll responde igual.
9. **Retro-compatibilidad del poll.** `/api/agent/poll` solo se AMPLÍA (campo huella aditivo, patrón de
   `print_jobs` del plan 0013). Agente viejo (sin huella) → 200, columnas en null, `out_of_area` por distancia
   como hoy. Test: poll con body viejo → 200 sin excepción.

## Non-goals (explícitos)
- **NO se toca el instalador para prender location** (Felix): Nelson lo enciende a mano; el respaldo Wi-Fi cubre
  el olvido.
- **NO API de geolocalización de pago** ni pin exacto con location-off: **diferido**; solo si Nelson lo pide.
- **NO geo-IP de respaldo** (la flota es **100% laptops con Wi-Fi** → la huella es universal).
- **NO desktops** — no se instala en desktops.
- **NO tiempo real / enforcement** (hereda plan 0005): auditoría hacia atrás; no impide nada.
- **NO ubicar a la persona** — se audita el EQUIPO; redacción honesta ("el equipo estuvo fuera del área").
- **NO cambia la semántica de distancia del plan 0005** cuando hay coords; el respaldo AÑADE un estado
  (fuera-por-huella, **sin** distancia), no reemplaza la evidencia de distancia.
- **NO cruza Windows vs huella en v1** (prioridad simple; el cruce para detectar drift = follow-up).
- **NO sube la cadencia del poll ni del GPS.**

## Contracts & ADR-locked areas touched
- **`POST /api/agent/poll` (contrato cross-repo, SUPERFICIE DE RIESGO — única ruta de escritura, ~216k/día):**
  solo se AMPLÍA (campo huella aditivo). Se CONSUME, no se rompe. La comparación de huella en el hub debe ser
  O(1) best-effort (como el cómputo de distancia actual), después de las escrituras existentes.
- **Datos sensibles (auditoría laboral):** hereda las reglas del plan 0005 (redacción honesta, RLS, retención).
  El respaldo Wi-Fi es una señal **más débil** (binaria, sin distancia) → debe etiquetarse como tal, nunca
  presentarse como equivalente a la distancia (crit 5).
- **Plan 0005 (audit) + 0008 (área por recurrencia):** se EXTIENDEN (nueva fuente + huella de referencia análoga
  al área). No se cambia su semántica de distancia.
- **`HardenLocation.ps1` (plan 0011 settings vigilados):** se AJUSTA para no enmascarar el off. Toca un guard
  **desplegado** → cuidado con el estreno (una regla nueva en un guard desplegado se auto-acusa el primer día en
  las máquinas existentes; preguntar el estreno, no solo la violación).
- **Regla de oro (fail-open, ADR 0002) + ADR 0001:** intactas — ubicación ortogonal al filtrado.
- **Migración nueva (verificar el número libre al construir — `git ls-tree` cada rama, no `ls`; la última en
  disco es 0028):** `designated_fingerprint` en `machines` + campos de huella en `machine_sample`. Una sola
  migración por PR.
- **`VERSION` bump + OTA** (cambio de agente).

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR.** Multi-área e interdependiente (escaneo en el agente + ajuste de un guard desplegado +
campo aditivo en la única ruta de escritura + comparación en el hub + migración + UI honesta) y **dos
superficies de riesgo**: la única ruta de escritura de la flota (un bug ahí ciega/tumba el monitoreo de todas
las máquinas) y **datos sensibles de auditoría laboral**. Revisor separado + gate E2E (test PC para el agente +
fixtures del hub). Serializar TODO el trabajo que toca DB por un solo agente.

## Open questions (para SOLVE — cada una con mi recomendación; piden sign-off de Felix)
1. **¿Dónde vive la comparación de huella y la huella de referencia — agente o hub?**
   → **Recomiendo HUB-SIDE:** el agente DEPOSITA la huella cruda; el hub guarda `designated_fingerprint` y
   compara. **Por qué:** consistente con el plan 0005 ("el poll deposita, el hub piensa" + área confirmada por
   humano); la referencia sobrevive reinstalaciones y es confirmable por admin. La alternativa agente-side tiene
   payload menor pero pierde la referencia en cada reinstalación y no es admin-confirmable.
2. **Umbral de "misma huella"** (% de solape de BSSIDs / Jaccard). → De **calibración empírica** en la test PC;
   propongo arrancar ~50 % de solape y afinar en VERIFY (un laptop se mueve DENTRO del local → hace falta
   tolerancia). El desempate lo da la medición real, no una discusión.
3. **Ajuste exacto del guard** (crit 7): ¿deja de escribir `Allow` en el consent per-user (el del toggle), o lo
   escribe pero SIEMPRE alerta + reporta el estado real del broker? → **Recomiendo:** mantener las palancas de
   máquina/GPO (evitan un hard-disable) pero **no enmascarar el per-user**; el estado reportado debe reflejar si
   el broker concede de verdad (no solo el registro).
4. **¿Cruzar Windows vs huella cuando ambos están** (para detectar drift/discrepancia)? → **Recomiendo NO en
   v1** (prioridad simple: Windows manda); el cruce = follow-up.

## Build — CONSTRUIDO + verificado (2026-08-06)
Aprobado por Felix con las 4 open questions tal como recomendé. Orquestado (revisor separado + Codex).

**Piezas:** agente — `GetWifiFingerprint.ps1` (nuevo, escaneo BSSID por netsh como SYSTEM, **probado en HW**),
`poll-hub.js` (`refreshWifiFingerprintIfDue`/`readWifiFingerprint` → `body.wifi_fingerprint`), `VERSION`→1.0.44.
Hub — `lib/audit/wifi-fingerprint.ts` (nuevo), migración `0029_wifi_fingerprint.sql`, `poll/route.ts` (respaldo +
insert tolerante), `machine-actions.ts` (`setDesignatedFingerprint`), UI (`page.tsx`+`location-panel.tsx`+i18n:
badge de método, disclaimer, acción fijar-huella), arnés `verify:wifi`.

**Decisiones de build (reportadas a Felix):**
- **Métrica = coeficiente de solape `|A∩B|/min`, NO Jaccard** — el set de antenas fluctúa (21→5 en HW); Jaccard
  leería "vi menos antenas del mismo sitio" como movimiento. Subconjunto → 1.0.
- **AC7 (ajustar el guard `HardenLocation`) DIFERIDO** — el badge de método (AC6) ya da la honestidad (la UI
  refleja la fuente REAL según qué dato llega, no el registro), así que tocar un guard anti-tamper desplegado da
  riesgo por poco valor. Follow-up.

**Revisión (revisor separado opus + Codex convergieron) — 7 hallazgos, TODOS arreglados:**
1. `designated_fingerprint` estaba en el `select` de auth → habría dado **401 a toda la flota** pre-migración →
   ahora se lee **separado + tolerante** en la rama de respaldo. 2. arnés asertaba Jaccard → reescrito a
   coef. de solape + caso subconjunto (29/29). 3. badge/mapa mostraban el veredicto Windows viejo en modo Wi-Fi →
   `wifiOut` + `displayedOut()` conducen badge/mapa por la huella. 4. una lectura reenviada contaba como N
   muestras → `wifi_at` + dedup por escaneo en la propuesta. 5. huella vieja sin TTL / re-escaneo cada poll →
   TTL 2h en el hub + touch de mtime en el agente. 6. `bssids:[null]`/oversized → `normalizeBssids` (regex MAC)
   en todos los bordes. 7. la query del badge excluía filas Windows-solo → query de `loc_source` separada.

**Verificación:** `tsc` 0 · `npm run verify` (todos los arneses + wifi 29/29) · `npm run build` verde · lint 0 en
archivos tocados · agente sintaxis OK + escáner probado en la test PC como SYSTEM (JSON válido).

## Lo que falta, y es de Felix (orden de despliegue IMPORTANTE)
1. **`supabase db push --linked` (migración 0029) PRIMERO** — el hub lee columnas nuevas; aunque el código es
   tolerante (no 401ea pre-migración), el respaldo Wi-Fi no funciona hasta que las columnas existen.
2. **Luego** deploy del hub (`vercel --prod --yes`) — sin CI, merge ≠ deploy, así que el merge es seguro antes.
3. **OTA del agente:** rebuild del bundle → copiar a `public/` → `publish-agent.mjs` (1.0.44).
4. E2E de producción (agente 1.0.44 + migración + poll real → `out_of_area` por huella) — se cierra con 1+2+3.
