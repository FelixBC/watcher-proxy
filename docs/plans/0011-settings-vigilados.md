# 0011 — Settings vigilados: historial visible + alerta de frecuencia

**Status:** **APROBADO por Felix (2026-07-30)** — gear **FULL-ORCHESTRATOR**, Q1–Q3 "como recomiendo".
En build vía `feature-orchestrator` (propose-only; sin commit/push/PR/merge). Cross-repo
(watcher-proxy + watcher-fleet). Origen: espejo `/aligned` confirmado; forks A/B/C/D resueltos.

**Directiva de Felix al aprobar:** costo bajo, pero la **barra histórica lo más fiel posible** —
para settings de Windows Y para el tráfico/auditoría del banquero, **cada una entendiendo sus
diferencias** (ver §Fidelidad histórica).

## Problema (una frase)

El agente **endurece** varios settings de Windows en silencio y hoy solo el revert de
**impresora Keep=OFF** se ve en el fleet (como una alerta binaria 🚩); no hay un lugar donde Nelson
vea, por máquina, **qué settings se vigilan, cuándo se confirmaron OK por última vez, su historial de
manipulaciones, y una alerta que suba de tono cuando a una banca la manipulan repetidamente**.

## Qué YA existe (no re-construir)

- `machine_tamper {machine_id, at, kind, detail}` (mig 0011) + índice `(machine_id, at desc)`.
- El poll (`/api/agent/poll`) ya inserta `tamper_events` (≤20, kind≤60, detail≤400) en esa tabla y
  estampa `machines.last_tamper_at`.
- Revert de **impresora Keep=ON → `tamper`** end-to-end, verificado en HW (v1.0.32, plan 0010).
- Alerta 🚩 **binaria**: `last_tamper_at` reciente (<7d) y `> tamper_seen_at` → flota arriba con chip
  + acción "marcar visto" (mig 0014, `fleet-view.tsx`).
- Patrón de historial+cron (mig 0019): poll deposita crudo sin razonar; un cron compacta; retención
  en `/api/cron/prune-logs`.

## Criterios de aceptación (cada uno testeable)

1. **Energía emite guard-event al ser revertida.** Si tras el endurecimiento (post-install) un
   re-check horario encuentra Wi-Fi power-saving o sleep-on-AC **vueltos a activar**, `HardenPower.ps1`
   los revierte **y** escribe un evento en el canal tamper con `setting=power` (espejo exacto del
   patrón `-Baseline` de impresora: la corrección de arranque NO es tamper). Verificable en HW: flipear
   el valor, correr el poll, ver la línea `tamper|setting=power` subir (cursor avanza tras post OK).
2. **Los guard-events llevan dimensión `setting`.** Solo los dos guards de primera clase emiten slug:
   `printer-keep` y `power`. Los eventos de un solo disparo (uninstall vía BackToNormal, AV, watchdog)
   y los de un agente viejo quedan con `setting=null` **por diseño** — no se le pone slug a uninstall
   (superficie anti-brick, y "3 desinstalaciones en 24h" no es una tasa): siguen en el historial con su
   detalle, pero fuera de la escalera de frecuencia. Aditivo y retro-compatible: `null` no rompe el insert.
3. **Sello "último OK" por máquina.** El poll reporta `guards_checked_at` (un timestamp: cuándo el
   re-check horario confirmó todos los guards OK). El fleet lo guarda; el panel muestra "confirmado
   hace ~Xm" con la **frescura real (~horaria)**, sin fingir 2-min.
4. **Panel "Settings vigilados" por máquina.** Lista una fila por setting de primera clase (impresora
   Keep, energía) con: estado actual (OK / alterado), "último OK", y un sparkline de reverts de los
   últimos 7 días leído de `machine_tamper`. Testeable: una banca con 2 reverts de impresora en la
   semana muestra 2 marcas rojas en su sparkline.
5. **Alerta graduada por frecuencia (reemplaza la binaria, no la duplica).** Contando reverts por
   setting en 24h: 1 = nota gris, 2 = ámbar, ≥3 = rojo al tope del dashboard. Umbral **configurable**.
   El conteo se computa en el **read path (dashboard) o un cron**, NUNCA en el poll. Testeable: 3
   reverts en 24h en una banca → chip rojo; bajar el umbral a 2 en config → una con 2 pasa a rojo.
6. **La acción "marcar visto" sigue funcionando** sobre la alerta graduada (no se pierde el ack).

## No-objetivos (cerca explícita anti-scope-creep)

- **NO** heartbeat de estado completo de todos los settings en cada poll (fork A). Solo eventos +
  `guards_checked_at`.
- **NO** razonar/contar/clasificar en el poll — es el hot write path (~216k/día a 300 bancas). El poll
  solo deposita el evento; el conteo de frecuencia vive en read/cron (doctrina mig 0019).
- **NO** meter proxy / whitelist / os_version como settings de primera clase en esta iteración (ya se
  reportan como estado; se suman después). Fork C: arranque = impresora + energía.
- **NO** un historial nuevo paralelo: se reusa `machine_tamper`, no una tabla de settings aparte.
- **NO** tocar la regla de oro ni el filtrado: los cambios de agente son ortogonales al proxy.

## Contratos y áreas ADR-tocadas

- **Cross-repo contract `POST /api/agent/poll`** — cambio **ADITIVO** (nuevo campo `setting` en cada
  `tamper_event`; nuevo `guards_checked_at` en el body). Actualizar los comentarios "cross-repo
  contract" en ambos repos. Consume, no rompe (viejo↔nuevo tolerado en ambas direcciones).
- **`machine_tamper`** — migración fleet (próxima libre: **0022**): columna `setting text` nullable +
  posible índice `(machine_id, setting, at desc)` para el conteo por setting.
- **Umbral configurable** — patrón `master_code_settings` (mig 0012): fila/tabla de config, RLS
  admin-only.
- **ADR 0002 (filter fails open)** — se **consume**, no se cambia: `HardenPower`/`HardenPrinters` son
  ortogonales al filtro; el reviewer debe confirmar que la emisión de eventos no toca
  ProxyEnable/routing.
- **`/api/cron/prune-logs`** — si el conteo usa un cron o una tabla nueva, su retención entra aquí
  (patrón 0019), no en una función SQL aparte.

## Fidelidad histórica + costo bajo (dos modelos de historial, no uno)

Directiva de Felix: el historial debe ser **fiel**, sin subir el costo. Hay **dos historiales de
naturaleza distinta** y NO se fuerza el mismo modelo sobre ambos:

- **Historial de SETTINGS = por EVENTOS (discreto).** Un setting o está bien o alguien lo manipuló;
  lo fiel es capturar **cada manipulación real, sin perder ninguna**. Ya lo garantiza el canal tamper
  forward-only (cursor avanza solo tras post OK; verificado en HW). Costo naturalmente bajo: solo
  escribe cuando algo se toca, no cada poll. Fidelidad = dimensión `setting` correcta + retención
  suficiente (`machine_tamper`, prune 0019/`prune-logs`). El "último OK" es el complemento barato
  (`guards_checked_at`, ~horario) para distinguir "confirmado bien" de "nunca revisado".
- **Historial de TRÁFICO / auditoría del banquero = por MUESTREO→INTERVALOS (continuo).** Ya existe
  (plan 0019: `machine_sample` crudo → cron compacta a `machine_activity` intervalos work/browsing/
  idle/offline → resumen diario `machine_day`). Lo fiel aquí es que la **compactación preserve la
  forma real de la actividad**; el costo se mantiene bajo porque el poll solo deposita crudo y el
  pensamiento vive en el cron (retención 60d audit / 3d feedstock).
- **Regla común de costo:** ningún conteo/razonamiento en el hot write path del poll (~216k/día a 300
  bancas). Eventos y muestras se depositan; la lectura/cron agrega.
- **En la UI se ven como dos barras distintas, no una:** settings = marcas discretas de manipulación
  (sparkline de reverts); tráfico = línea continua de estados. Que se lean coherentes como "el
  historial de esta banca", pero cada una con su forma.

**No-objetivo añadido:** NO reconstruir ni degradar el pipeline de auditoría 0019 — este feature lo
**complementa**. Mejorar activamente la fidelidad del historial de tráfico es un plan aparte (se
propone como follow-up si Felix lo pide), no parte de este build.

## Gear recomendado (a confirmar por Felix)

**FULL-ORCHESTRATOR.** Multi-área e interdependiente y cruza dos repos: scripts PS del agente
(`HardenPower.ps1`) + payload del poll (agente) + `route.ts` del poll (fleet) + migración DB (fleet) +
panel nuevo + alerta graduada sobre UI existente + config. Superficies de riesgo que obligan a escalar:
(a) el **hot write path** del poll (escala/egreso), (b) camino de hardening **adyacente a la regla de
oro** en el agente, (c) **cambiar una alerta que ya funciona** (la binaria → graduada). Reviewer
separado + gate E2E en el test PC (staging) antes de publicar OTA.

## Preguntas resueltas (Felix, "como recomiendo", 2026-07-30)

- **Q1 → RESUELTA:** `guards_checked_at` queda **~horario** (frescura real; el panel dice "hace ~Xm",
  sin fingir). Barato a 300 bancas.
- **Q2 → RESUELTA:** la alerta graduada **reemplaza** la binaria 🚩 (mismo chip, ahora con nivel), no
  una segunda.
- **Q3 → RESUELTA:** default **≥3 en 24h = rojo** (2 = ámbar, 1 = gris), **configurable** por Nelson.

## Próximo paso

Con tu aprobación del lock → `feature-orchestrator` (gear arriba): research → solve/green-loop →
decompose por repo/área → implementar en worktrees aislados → verificar contra E2E en staging antes de
OTA. El plan companion del lado fleet se abrirá en el tracker de watcher-fleet al construir esa parte.
