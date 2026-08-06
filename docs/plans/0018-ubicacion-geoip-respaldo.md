# Plan 0018 (watcher-proxy) — Ubicación: geo-IP como respaldo real + alerta de "Location apagado"

Estado: **DEFINIDO — lock pendiente de Felix (2026-08-06).** CORRIGE/SUPERSEDE el respaldo del plan 0017.
Cross-repo: agente (watcher-proxy) → VERSION + OTA; extiende la auditoría del hub (watcher-fleet plan 0005/0008).

## Problem (una frase)
El respaldo del plan 0017 (huella Wi-Fi) **no puede cubrir "Location apagado"** — en Windows 24H2 el escaneo de
BSSID también está bloqueado detrás de Location services (verificado) — así que la auditoría "¿trabajó desde su
puesto?" sigue **sin ningún respaldo** cuando alguien apaga Location; hace falta una fuente que funcione con
Location apagado (**geo-IP**) y una **señal de que lo apagaron**.

## Contexto verificado (test PC, 2026-08-06)
- **Location OFF** → `netsh wlan show networks` = **0 antenas** ("Network shell commands need location
  permission… Turn on Location services"); Windows Location = no-fix. **Location ON** → netsh **35 antenas** +
  Windows fix **±89 m**. Conclusión: el escaneo Wi-Fi **NO es respaldo** (necesita Location on, redundante con
  Windows Location). La premisa del 0017 era falsa (Codex lo advirtió; se descartó por error).
- **geo-IP por Node (directo, salta el filtro localhost)** con Location OFF → `https://ipapi.co/json/` devolvió
  Santiago de los Caballeros, `19.450,-70.700`, a **1.8 km** del punto preciso real. Node ya vive en la máquina
  (`WatcherBrain\node\node.exe`) y va directo (por eso alcanza el hub). geo-IP lee la IP pública, **no toca
  Windows Location** → es lo ÚNICO que sobrevive a Location apagado. (PowerShell daba 404 porque usa el proxy
  del sistema = el filtro; Node no.)
- **GetLocation.ps1** err codes (`no-fix`/`denied`/`disabled`/`no-hardware`) **NO distinguen fiablemente**
  "Location apagado" de "no triangula": con Location off dio `no-fix` (LocationStatus `NotInitialized`), no
  `denied`. → la alerta (AC6) NO puede basarse en el err code (ver Open Q4).

## Diseño elegido (Felix + mis recs — aprobado en el espejo del mapa)
- **REVERTIR el respaldo Wi-Fi del 0017** (agente `GetWifiFingerprint.ps1` + su wiring; hub `wifi-fingerprint.ts`
  + la rama de comparación). Queda muerto. Las columnas ya desplegadas de la migración 0029
  (`wifi_bssids`, `wifi_at`) **se DEJAN** (no se dropean columnas en producción), sin uso.
- **AGENTE:** geo-IP por Node (directo) **solo cuando Windows Location no da fix fresco**; **cacheado** (re-consulta
  solo si la IP pública cambió o venció un TTL de ~horas) → banca quieta ≈ 1 llamada/día → cabe en tier gratis a
  escala de **Florida** (muchas máquinas). Servicio: `ipapi.co` (https, sin llave, funcionó por Node).
- **HUB:** la lectura geo-IP se guarda con `loc_source='geoip'` + su precisión; el "fuera del puesto" usa un
  **radio grueso CONFIGURABLE** (default ~10 km "misma ciudad", **NO** 200 m); **nunca** muestra una distancia fina.
- **UI:** etiqueta "aproximada por IP · ~ciudad · radio ~X km", distinta de la precisa (±80 m Windows); en el
  MAPA un **CÍRCULO grande** (radio ~ciudad) en vez de pin (fork A); el último pin preciso de Windows en gris
  **solo si es reciente** (fork B); mensaje explícito de menor precisión.
- **ALERTA "Location apagado"** (AC6, el AC7 antes diferido): señal fuerte anti-evasión (apagar Location esconde
  AMBAS fuentes → esa ausencia + geo-IP en otra ciudad = bandera roja).
- **Florida-adaptable:** radio/precisión **configurable**, no hardcodeado a los 1.8 km de aquí (fork C).

## Acceptance criteria (numeradas, testables)
1. **Respaldo geo-IP SOLO con Location off.** Con un fix fresco de Windows, el agente NO llama geo-IP (Windows
   primario, sin regresión). Sin fix fresco (Location off / no-fix) → llama geo-IP. Test: poll con fix fresco →
   no hay llamada geo-IP; poll sin fix → sí.
2. **geo-IP cacheado — ≤1 llamada por ventana TTL, no por poll.** Test: N polls seguidos con la misma IP →
   exactamente 1 llamada HTTP en la ventana; a 300 máquinas quieta ≈ 1/día → dentro del tier gratis.
3. **Hub: lectura geo-IP con `loc_source='geoip'`; in/out por radio grueso CONFIGURABLE** (default ~10 km),
   nunca 200 m ni distancia fina. Test: geo-IP dentro del radio → "en el puesto (misma ciudad)"; fuera → "otra
   ciudad"; y NUNCA produce un `distance_m` fino para geoip.
4. **UI honesta (requisito de Felix):** una lectura geoip se etiqueta "aproximada por IP (~ciudad, radio ~X km)";
   el mapa dibuja un **círculo** del radio, no un pin; el último pin preciso de Windows aparece en gris **solo si
   es reciente**; hay un **mensaje explícito** de menor precisión. Test: los 3 estados (preciso / geoip-misma-
   ciudad / geoip-otra-ciudad) renderizan + las claves i18n nuevas.
5. **Cero falsa precisión.** Una lectura geoip NUNCA muestra ±80 m, un veredicto de 200 m, ni una distancia fina.
   Test: el render está gated por `loc_source`, no por la existencia de una coord.
6. **Alerta de "Location apagado".** Cuando una máquina que **tenía fixes precisos de Windows** deja de tenerlos y
   cae a geo-IP, se emite una alerta (tamper) "Location apagado" para esa banca, **deduplicada por transición**
   (no se repite cada hora). Una máquina que NUNCA tuvo fix de Windows (no triangula) **no** dispara. Test:
   transición con-fix → sin-fix emite 1 alerta; sin-fix sostenido no la repite. (Detección: ver Open Q4.)
7. **Radio/precisión configurable (Florida-adaptable), no hardcodeado.** Test: cambiar el radio (config) cambia
   el umbral in/out sin tocar código.
8. **Revertida la huella Wi-Fi muerta.** No corre ningún escaneo BSSID; el poll ya no manda `wifi_fingerprint`;
   la comparación wifi del hub se elimina. Las columnas `wifi_bssids`/`wifi_at` (0029) se dejan sin uso (no se
   dropean). Test: grep sin `GetWifiFingerprint`/`fingerprintOut` en las rutas vivas; el poll no lleva el campo.
9. **Regla de oro + best-effort.** El fetch geo-IP nunca falla un poll, no toca `ProxyEnable`/el filtro, está
   time-boxed. Test: geo-IP que falla/tarda → el poll responde 200 igual.
10. **Retro-compat + orden de despliegue.** `/api/agent/poll` solo se amplía (campo geoip aditivo); agente viejo
    → 200. Migración 0030 (fleet) se aplica ANTES del deploy del hub (mismo patrón que 0017).

## Non-goals (explícitos)
- **NO precisión sin Location on** — geo-IP es grueso por naturaleza (~ciudad). Los movimientos finos (cuadras)
  solo se detectan con Location encendido.
- **NO detectar movimientos intra-ciudad** por geo-IP (solo cambio de ciudad).
- **NO un segundo servicio geo-IP** en v1 (ipapi.co + fallo best-effort; revisar si hace falta).
- **NO tier de pago** de geo-IP de entrada (tier gratis + caché; revisar si la escala lo exige).
- **NO forzar Location on** — el agente no puede; Nelson lo prende a mano.
- **NO conservar la huella Wi-Fi** (revertida) — pero **NO dropear** las columnas 0029 ya desplegadas.
- **NO tiempo real / enforcement** (hereda 0005).
- **NO subir la cadencia del poll.**

## Contracts & ADR-locked areas touched
- **`POST /api/agent/poll` (SUPERFICIE DE RIESGO — única ruta de escritura ~216k/día):** solo se amplía (campo
  geoip aditivo). El cómputo in/out debe ser O(1) best-effort.
- **NUEVA dependencia externa (servicio geo-IP):** rate limits, caídas, coste a escala. **La caché es esencial**
  y el fallo debe ser best-effort (una caída del servicio no afecta el poll ni el filtro). El fetch lo hace el
  AGENTE (Node, directo), no el hub — el hub solo recibe la coord.
- **Plan 0005/0008 (audit):** se extiende (fuente gruesa nueva + radio de ciudad). No cambia la semántica de
  distancia precisa.
- **Plan 0017:** su respaldo Wi-Fi se **REVIERTE** (superseded). Documentar que 0017 queda como "Windows Location
  primario" + este 0018 como el respaldo real.
- **`HardenLocation.ps1` / guard (plan 0011):** la alerta de "Location apagado" toca la lógica de un guard
  **desplegado** → cuidado con el estreno (auto-acusación el primer día).
- **Regla de oro (fail-open, ADR 0002) + ADR 0001:** intactas — geo-IP ortogonal al filtrado.
- **Migración 0030 (fleet, verificar libre al construir):** radio geo-IP configurable + campos geoip; NO dropea
  las de 0029. Una migración por PR.
- **`VERSION` + OTA.**

## Recommended gear (a confirmar por Felix)
**FULL-ORCHESTRATOR.** Multi-área e interdependiente (agente geo-IP + revertir Wi-Fi + alerta en guard desplegado
+ campo aditivo en la única ruta de escritura + comparación gruesa + migración + UI del mapa) y **tres superficies
de riesgo**: la única ruta de escritura de la flota, una **dependencia externa nueva** (servicio geo-IP), y datos
sensibles de auditoría laboral. Revisor separado + Codex + gate E2E (test PC + fixtures del hub).

## Open questions (para SOLVE — cada una con mi recomendación; piden sign-off)
1. **Servicio + caída.** → **ipapi.co** primario; en fallo/rate-limit → "sin geoip este ciclo" (best-effort),
   **NO** un segundo servicio en v1. El desempate (añadir secundario) lo daría ver rate-limits reales en Florida.
2. **Dónde vive el radio configurable.** → **default global (~10 km) + override por-máquina** (como
   `area_radius_m`), para tunear Florida global y casos especiales por banca.
3. **TTL de caché + detección de cambio de IP.** → **TTL ~6 h + reset si la IP** (que viene en la respuesta
   geo-IP) cambió. Simple y suficiente para una banca quieta.
4. **⚠️ Detección de "Location apagado" para la alerta (AC6) — la más delicada.** GetLocation err es ambiguo y el
   registro no refleja el estado real del broker. → **Recomiendo basar la alerta en la TRANSICIÓN**: la máquina
   tuvo fix preciso de Windows en las últimas ~24 h y ahora no → alerta "Location apagado" (aunque también
   dispararía si Location se rompe por otra causa). Una máquina que NUNCA tuvo fix (no triangula) no dispara. Es
   la señal más fiable disponible; si resulta ruidosa, se afina el umbral o se degrada a "aviso" en vez de tamper.

## Build — CONSTRUIDO + verificado (2026-08-06)
Aprobado por Felix ("va, dale con el orquestador"). Orquestado (revisor separado opus + Codex, cegueras disjuntas).

**Piezas:** agente — `poll-hub.js` (`refreshGeoIpIfDue` + `readGeoIp` + `GEOIP_PROVIDERS` fallback + attach `body.geoip`; escaneo Wi-Fi revertido), `GetWifiFingerprint.ps1` BORRADO, VERSION→1.0.45, bundle /descargar→1.0.45. Hub — `poll/route.ts` (rama geo-IP coarse + alerta Location-off por transición; revert Wi-Fi), migración `0030_geoip_radius.sql`, `machine-actions.ts` (setDesignatedFingerprint borrado + guard anti-geoip en setDesignatedArea), UI (`page.tsx`/`location-panel.tsx`/`location-map.tsx`/i18n), borrados `wifi-fingerprint.ts`+`verify-wifi.cjs`.

**Decisiones de build (verificado en HW):** `getText`→geo-IP funciona por Node directo; **429 real** de ipapi.co (rate-limit) → **dos proveedores HTTPS** (ipapi.co→ipwho.is, ambos probados). Alerta Location-off SIN columna nueva (transición de `last_location.source`).

**Revisión — 10 hallazgos, todos resueltos o aceptados:**
- Codex: #1 P0 fijar-área-desde-geoip → enforcement server + botón deshabilitado. #2 P1 fix geo-IP viejo reenviado → **marker de throttle SEPARADO + TTL de frescura (agente + hub)**. #3 P1 HTTP MITM → **HTTPS-only**. #4 P1 `getText` sin deadline absoluto → `withDeadline` + cap de tamaño + rango de coords. #5/#7 P2 mapa no encuadra el círculo / panel muestra 200m+coords precisas → arreglados (círculo encuadrado, radio grueso, coords a 2 decimales con "≈", copy oculto).
- **Revisor separado (lo que Codex NO vio):** **#1 HIGH — la alerta con `setting:"location"` NO se veía en el panel** (zona muerta entre `machines_with_unseen_oneshot` y los umbrales) → `setting:null` (flota como one-shot serio). **#2 MEDIUM — auto-acusación el estreno** (last_location pre-0018 sin `source`) → exigir `prevSource === "windows"`.
- **Aceptados:** Codex #6 (doble-alerta si falla el update de la máquina — P2 bajo riesgo). Revisor #3 (TTL-only sin reset-por-IP — per Open Q3; el campo `ip` queda de breadcrumb).

**Verificación:** tsc 0 · `npm run verify` (478 checks) · build 0 · lint 0 · agente sintaxis OK + `getText`→geo-IP (ipapi.co/ipwho.is) probado en la test PC.

## Lo que falta, y es de Felix (orden IMPORTANTE)
1. **`supabase db push` (migración 0030) PRIMERO** (deploy-fleet.sh lo hace en orden).
2. Deploy hub (`vercel --prod`), luego OTA agente 1.0.45 (`publish-agent.mjs`). Bundle /descargar ya en 1.0.45.
3. E2E: instalar/OTA 1.0.45 → con Location ON verificar Windows preciso; apagar Location → esperar el respaldo geo-IP (~ciudad) + la alerta "Location apagado" flotando roja.
