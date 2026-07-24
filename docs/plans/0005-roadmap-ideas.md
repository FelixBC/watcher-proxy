# Plan 0005 — Roadmap / backlog de ideas (watcher-proxy + watcher-fleet)

Estado: **CAPTURA** — banco de ideas de Felix para no perderlas. No es orden de ejecución;
es el registro durable de lo hablado (sesión 2026-07-23). Propose-only hasta que Felix diga va.

## Flujo de trabajo acordado (QA / review loop)
Para cada prueba/release:
1. **Yo** actualizo Vercel + publico la "última versión" (deploy watcher-fleet + `publish-agent.mjs` con VERSION bumpeado).
2. **Felix** descarga en la PC Windows + la ejecuta (instalación real + wizard, en pantalla).
3. Felix avisa que está lista (o yo lo detecto: la máquina **aparece reportando en el fleet**).
4. **Yo** pruebo: reviso los **logs** (events.log/blocked), miro el **fleet**, busco algo raro a considerar.
5. Se lo mando a **Codex** (cross-review) + le explico; si recomienda algo, escuchamos su propuesta.
6. **Artefacto** para revisar cómo quedó.
7. Decidimos: hacer cambios o seguir con la otra prueba.

## Filosofía del whitelist (NO perderla)
- El proxy **VE todo** el tráfico — no solo browsing, también los programas/APIs que salen a internet sin navegar. **Eso es bueno**: da control + auditoría de lo que realmente entra/sale.
- Los dominios **conocidos-benignos** (utilidades del SO, infra de Google/Microsoft, herramientas) **se AGREGAN al whitelist default** — NO se ignoran ni se ocultan, se **aceptan**. Así dejan de ensuciar la lista de bloqueados.
- Lo que **queda bloqueado = SEÑAL real**: un programa nuevo/inesperado intentando salir → ahí Nelson decide permitir o no. La lista de bloqueados pasa a ser una **auditoría limpia**, no ruido.
- Regla: cualquier cosa que se instale queda controlada y auditada en la app.

## Ideas / backlog

### A. Whitelist como señal de auditoría limpia
- Agregar al **whitelist default** los dominios de SO/infra que hoy salen bloqueados como ruido (Windows telemetry, updates, Google gvt/beacons, etc.). *(Base ya agregada esta sesión; faltan los de Google/sistema que AÚN salen en TEST 01 — agregarlos, no sacarlos.)*
- Objetivo: que la lista de bloqueados solo muestre lo que de verdad hay que revisar.

### B. "Agregar a whitelist" desde la lista de bloqueados + whitelist PERMANENTE (fleet)
- Botón **"agregar a whitelist"** en la vista de bloqueados del fleet → manda el dominio al whitelist.
- Un **whitelist permanente** (el bloque manejado del fleet, que se pushea a todas) — que **no se pueda borrar por accidente**, siempre ahí con los datos, en el fleet.
- Así: dominio bloqueado → un clic → queda permitido permanentemente en todas.

### C. Dashboard pulido — horas exactas
- La **hora exacta** en que la PC se encendió y le dio oportunidad al watcher de "latir" (primer poll/heartbeat del día).
- Su **primera página** del día (first-visit).
- Todo en la **zona horaria correcta** (ver E).

### D. Detectar intento de desactivar el spool (anti-robo) → tamper
- HardenPrinters ya revierte Keep=ON; falta que lo **reporte como `tamper`** (no solo log local) → fluye al fleet + a la **alerta roja** ("intentó retener tickets").
- También detectar si **borran/desactivan la tarea del spool**.
- Encaja con la alerta de tamper ya construida (0004-ish).

### E. Fix de zona horaria (dashboard → Eastern/Florida fijo)
- Guardado ya es UTC (bien). El DISPLAY tiene líos:
  - El "día" de asistencia se calcula en **UTC** (rueda a medianoche UTC = 7-8pm Florida) → mal.
  - El "hoy" del detalle se calcula en el **servidor Vercel=UTC**, no en la hora del viewer (bug; su comentario miente).
  - Horas en paneles client salen en la hora del navegador — inconsistente.
- Fix: fijar el dashboard a **America/New_York (Florida/Este)** para el día + las horas absolutas, así Felix siempre ve todo en SU hora operativa sin importar dónde esté la máquina.

## Ya hecho esta sesión (propose-only, code-complete)
Detalle en 0003 (P0 + wizard + anti-brick + hardening) y 0004 (wizard define). Resumen:
crash-loop/EADDRINUSE, anti-brick (armado⟺hash), wizard install/uninstall, HardenPrinters
(Keep=OFF), banca obligatorio, orden por banca (fleet), whitelist base + WhatsApp, abracadabra,
código de emergencia SOS, **puertos obscuros + fallback**, poll-hub forward-only, alerta de
tamper (fleet, migración 0014). Verificado en HW lo que se pudo (ver 0003 §VERIFICADO).

## Pendiente antes de pushear
QA integrado real (Felix instala vía descarga+wizard → yo verifico estado + logs + fleet →
Codex → artefacto → decidir). Deploys: watcher-fleet (`vercel --prod`) + publicar bundle/versión.
