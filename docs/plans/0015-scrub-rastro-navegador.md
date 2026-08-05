# 0015 — Borrar el rastro del hub del historial del navegador, en la instalación

**Estado:** DESCARTADO (Felix, 2026-08-05). Más lío que beneficio: sqlite3.exe + riesgo AV + corromper perfil + trampa WAL, para una ganancia marginal. Además, post-instalación el hub YA está bloqueado de facto (no está en el whitelist). El rastro se ataca en el ORIGEN sin código: repartir el `.bat` por USB (baja por PowerShell, no por navegador → nunca crea rastro); y, opcional, un dominio neutro para `/descargar`. NO construir.
**Repo:** watcher-proxy (paso nuevo en el instalador + `sqlite3.exe` en el bundle). Cambio de agente → VERSION bump + OTA.
**Origen:** hilo 2026-08-05. Instalar puede dejar `watcher-fleet.vercel.app` (p. ej. `/descargar`, `/login`) en el historial del navegador de la banca; Felix no quiere ese rastro en cada máquina.

---

## Problema (una frase)

La instalación puede dejar la URL del hub en el historial del navegador de la banca, delatando el sistema a un banquero curioso.

## Contexto que acota el alcance

El **agente habla con el hub por HTTP de Node, no por navegador** — esas peticiones NO entran al historial. El único rastro de navegador posible es una **navegación humana** a `watcher-fleet.vercel.app` (típicamente `/descargar` para bajar el `.bat`, o `/login` si alguien abrió el panel en esa PC). Por eso el scrub corre **en la instalación** (donde ese rastro ya existe) y **una sola vez**.

## Acceptance criteria

1. **Un paso nuevo en la instalación** (Step 8 finalize de `InstallWatcher.bat`) borra del historial toda entrada cuyo host sea el del hub — **el host se deriva de `HubConfig.json`** (`new URL(HubUrl).host`), no hardcode, para sobrevivir un cambio de dominio.
2. **Borrado TARGETED, no total:** solo se borran las filas del host del hub (`urls`/`visits` de Chromium, `moz_places`/`moz_historyvisits` de Firefox). El resto del historial queda intacto — borrar todo sería MÁS sospechoso. Verificable: una URL cualquiera del historial sigue ahí tras el scrub; la del hub no.
3. **También muere el autocompletar:** tras el scrub, teclear "watcher" (o el host) en la barra de direcciones **no sugiere** el hub. (Cubre las tablas de omnibox/typed: `keyword_search_terms`, `segments` en Chromium; `moz_inputhistory` en Firefox.) Verificable a ojo en la test PC.
4. **Cobertura:** Chrome, Brave, Edge (Chromium), Firefox — **todos los perfiles** (`Default`, `Profile N`) de **todos los usuarios** (`C:\Users\*`, la instalación es elevada).
5. **Mata el proceso si está abierto:** si el navegador corre, se mata (`taskkill`) para soltar el lock del SQLite y poder editar. Aceptable porque solo ocurre durante la instalación de Nelson. No se reabre después.
6. **Correctitud con WAL:** las visitas recientes pueden estar en el `-wal` (matar el proceso NO hace checkpoint), así que el borrado usa un **motor SQLite real** que lee el WAL — no un lector de bytes crudo que lo perdería. Verificable: navegar al hub y CERRAR mal el navegador, luego scrub → la entrada no queda.
7. **BEST-EFFORT / fail-open, SIEMPRE:** cualquier fallo (navegador no encontrado, lock pese al kill, sqlite ausente, perfil raro) → **log y seguir, dejar el rastro, NUNCA bloquear ni abortar la instalación**. Verificable: con un `History` bloqueado a mano, la instalación termina OK igual.

## No-objetivos (la valla anti-scope)

- **La copia sincronizada en la nube.** Si el navegador está logueado con cuenta Google/Firefox, el historial vive también en la nube; el borrado local no la toca. Fuera de alcance (no se puede localmente).
- **Navegación POST-instalación.** El scrub es install-time; si alguien navega al hub DESPUÉS de instalar, no se limpia. Aceptado.
- **Navegadores fuera de los 4.** Si alguien usa Opera/Vivaldi/otro, se deja el rastro (minoría despreciable, dijo Felix). No error.
- **Borrar TODO el historial** o el archivo `History` entero. Solo filas del host del hub (AC2).
- **Dominio neutro para `/descargar`.** Idea complementaria, NO este feature (elimina el rastro de raíz sirviéndolo desde un dominio que no delata; se evalúa aparte).
- **Reabrir el navegador** tras matarlo. Queda cerrado.

## Contratos y zonas de riesgo tocadas

- **Golden rule (fail-OPEN):** NO se toca — este paso no toca proxy/internet/watchdog. Pero HEREDA la misma filosofía: fail-open literal (AC7).
- **Disfraz + exclusión AV (Step 3):** `sqlite3.exe` va **dentro de `WatcherBrain\` (carpeta ya excluida del AV)**. Editar el historial del navegador es, textualmente, el patrón que un antivirus marca (lo comenta `self-update.js:318`); meterlo bajo la exclusión mitiga el on-access scan. **Riesgo residual a firmar por el revisor:** que un `sqlite3.exe` sin firmar + comportamiento de "editar historial" dispare detección heurística pese a la exclusión.
- **Bundle `/descargar` + OTA:** el `sqlite3.exe` entra al `winconfig-install.zip` (ojo `build-winconfig-bundle.sh`) y al OTA. VERSION bump.
- **Riesgo de corromper un perfil de navegador:** editar el SQLite del navegador mal puede corromper el perfil del usuario (daño visible). El motor real + operación atómica + fail-open lo acotan; el revisor separado lo firma.

## Gear recomendado (a confirmar por Felix)

**FULL-ORCHESTRATOR (ligero)** — superficie de riesgo: anti-forense/disfraz + mata procesos + edita el SQLite del navegador (corromper un perfil o un flag de AV son daños reales), y es cambio de agente con OTA. Un **revisor separado** firma la seguridad del kill/SQLite/WAL/fail-open + **E2E en la test PC**. Ligero porque es ~1 script nuevo + 1 hook + el binario + el release; el golden-rule y el resto del agente no se tocan. Si prefieres, es defendible SINGLE-CONCERN con revisor obligatorio — tu llamada.

## Preguntas abiertas

- **Q1 — Método SQLite.** Recomiendo **empacar `sqlite3.exe`** (~1.5 MB) dentro de `WatcherBrain\` y hacer shell-out (`sqlite3.exe History "DELETE FROM urls WHERE url LIKE '%host%'; ..."`). Razón: es el único que lee el **WAL** correctamente (AC6) y es **independiente de la versión de Node** (que el agente ni pinea). Alternativas descartadas: `node:sqlite` (pide Node ≥22.5 + flag experimental, y el agente descarga cualquier Node), `sql.js`/WASM (carga el archivo crudo → **se pierde el WAL**). **← única decisión de fondo.**
- **Q2 — ¿El paso lo escribe un `scrub-browser-history.js` (Node, consistente con WatcherBrain, testeable) o un `.ps1`?** Recomiendo **Node** (encaja con el agente, `child_process` para taskkill/sqlite3, fácil de probar). Detalle de build, no bloquea.
- **Q3 — Sospecha del binario.** Si te preocupa el `sqlite3.exe` sin firmar, alternativa: renombrarlo con nombre neutro dentro de la carpeta (p. ej. `wcfg-sq.exe`) para no gritar "sqlite". Lo decidimos en build.
