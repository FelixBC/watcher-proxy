# Plan 0004 — InstallerWizard.ps1 (asistente WinForms «WinConfig»)

Estado: **APROBADO (gear SINGLE-CONCERN + revisión de seguridad) — EN CONSTRUCCIÓN.** propose-only.
Sucede a la Parte 2 del plan 0003 (que queda como el sketch original). Aprobado el
diseño visual por Felix vía espejo + prototipo interactivo (2026-07-23).
Decisiones de Felix: gear = SINGLE-CONCERN + revisión adversarial obligatoria; secreto = env var (v1);
**+ el UNINSTALL también con wizard.**

## AÑADIDO — Uninstall wizard (mismo patrón, sin tocar BackToNormal)
Un solo script parametrizado `WinConfigWizard.ps1 -Mode Install|Uninstall`.
- **Install:** 4 campos → env vars (`WATCHER_MASTER_CODE`/…) → corre `InstallWatcher.bat` oculto → barra `[n/8]`.
- **Uninstall:** 1 campo (código maestro) → corre `BackToNormal.bat` oculto → barra `[n/5]` → «Listo, internet normal» / «Código incorrecto».
- **Mecanismo (respeta "no moverlo" de BackToNormal — CERO ediciones):** el `.bat` corre vía
  `cmd /c "<bat>" > "<logfile>" 2>&1`; un `Forms.Timer` (hilo UI) sondea el logfile para `[n/N]`
  y `HasExited`. El **código maestro va por el pipe de stdin EN MEMORIA** (`RedirectStandardInput`;
  nunca en línea de comando ni en disco) — el `set /p WATCHER_UNINSTALL_CODE=` de BackToNormal lo
  lee tal cual. Para install, stdin se cierra (EOF → los `pause` retornan) e identidad va por env vars.
- Etiquetas de disfraz uninstall (map `[n/5]`): Restaurando configuración de red / Deteniendo servicio /
  Quitando inicio automático / Quitando tareas programadas / Finalizando.

## Problema (una frase)
Hoy el instalador se presenta como 4 popups sueltos (`AskIdentity.ps1`) + una consola
`InstallWatcher.bat`; se necesita una envoltura WinForms tipo asistente titulada
«WinConfig» que recoja los datos en un solo formulario y muestre progreso + resultado,
**sin tocar la lógica de instalación ni el orden golden-rule**.

## Criterios de aceptación (cada uno verificable)
1. Doble-clic en el entry point del bundle → aparece UNA ventana WinForms titulada
   **«WinConfig»** con los 4 campos; **NO** aparece ninguna consola visible. *(bifurcación A(b))*
2. **«Instalar» deshabilitado** mientras el campo **Código maestro** esté vacío; se habilita
   al escribir. El campo va **enmascarado** (no muestra el texto).
3. Al pulsar «Instalar», el wizard corre `InstallWatcher.bat` **OCULTO** (sin consola),
   pasando identidad por el **contrato de entorno desatendido** (`WATCHER_MASTER_CODE` /
   `_MACHINE_NAME` / `_ZONE` / `_CODE`) — sin modificar el .bat.
4. La barra avanza leyendo las líneas **`[n/8]`** de la salida del .bat, mostrando
   **etiquetas genéricas de disfraz** (nunca "proxy"/"antivirus"/"Watcher"/"fleet") +
   "Paso N de 8". *(bifurcación B — necesaria: el texto real del .bat sí revela esas palabras)*
5. `InstallWatcher.bat` sale **0** → pantalla **«Listo»** (check + estado en lenguaje de
   disfraz). Sale **≠0** (incl. el desarme anti-brick) → pantalla **«No se completó — el
   equipo quedó normal»** con Reintentar/Cerrar. *(refleja el anti-brick del 0003)*
6. El wizard corre **elevado (UAC)**, igual que hoy; si se lanza sin privilegios, se
   auto-eleva antes de mostrar el formulario.
7. **Fallback:** si WinForms no puede cargar/mostrarse, cae al camino actual (consola +
   popups de `AskIdentity`) sin bloquear la instalación.
8. `install.ps1` (bootstrapper) lanza el wizard en vez de `InstallWatcher.bat` directo
   (hoy: `install.ps1:173 Start-Process InstallWatcher.bat -Wait`). `InstallWatcher.bat`
   sigue funcionando **standalone (consola)** como fallback.
9. El **código maestro nunca** se escribe en logs ni queda en disco tras instalar (se apoya
   en el scrub que ya hace `InstallWatcher` Step 7 / `:CLEANUP`); el campo **siempre inicia
   vacío**. *(bifurcación C + seguridad)*
10. Ninguna máquina queda "armada sin hash": el wizard **hereda** el desarme del .bat, no lo
    evita ni lo enmascara (si el .bat sale ≠0 y desarmó, el wizard muestra «No se completó»).

## No-goals (cerca explícita anti-scope-creep)
- **NO** tocar la crypto del master-code (`agent-code-crypto.js`) ni el gate de `BackToNormal.bat`.
- **NO** cambiar el orden de pasos ni la lógica golden-rule de `InstallWatcher.bat`.
- **NO** arreglar el aviso de SmartScreen (eso es firma de código → v2).
- **NO** re-enrolar ni tocar el hub; el enroll sigue dentro del .bat.
- **NO** manejar el rollout en serie de las ~40 terminales por el wizard — eso va por el
  **modo desatendido scripted** (env vars) que ya existe. *(bifurcación C)*

## Contratos que toca
- **Consume** (no cambia): el contrato de entorno desatendido de `AskIdentity.ps1`
  (`WATCHER_MASTER_CODE`/`_MACHINE_NAME`/`_ZONE`/`_CODE`) — construido el 2026-07-23.
- **Consume** (no cambia): el contrato de salida **`[n/8]`** de `InstallWatcher.bat` (8 pasos
  fijos) + su **código de salida** (0 = ok; ≠0 = incompleto/desarme).
- **Consume** (no cambia): master-code crypto/gate + orden golden-rule.
- No hay `docs/adr/` ni CLAUDE.md en el repo → el "do-not-touch" es informal (golden rule +
  master-code). El wizard los **consume**, no los cambia.

## Punto de integración / mecanismo (resuelto desde el código)
- **Entry point:** un launcher mínimo (p.ej. `Instalar.bat` o un `.lnk`) que se auto-eleva y
  corre `powershell -WindowStyle Hidden -File InstallerWizard.ps1` (sin flash de consola).
- El wizard: recoge campos → setea las env vars → corre `InstallWatcher.bat` oculto con
  stdin=NUL (para que los `pause` retornen) → lee stdout en streaming, mapea `[n/8]` → barra
  → detecta el exit code → «Listo» / «No se completó».

## Preguntas abiertas (para Felix)
- **P1 — Gear.** Rec: **SINGLE-CONCERN con revisión adversarial separada OBLIGATORIA** enfocada
  en (a) manejo del secreto (no leak/log/residuo, enmascarado, scrub) y (b) golden-rule /
  anti-brick intactos. El footprint es chico (1 archivo nuevo + 1 wiring + launcher), pero el
  wizard **maneja el código maestro** (superficie sensible), así que el skill sesga a escalar —
  si prefieres máxima seguridad, subimos a **FULL-ORCHESTRATOR**. Tu decisión.
- **P2 — Manejo del código maestro.** Hoy el plan es pasarlo como **variable de entorno**
  (`WATCHER_MASTER_CODE`) al proceso hijo — consistente con el modelo transitorio actual (que
  igual lo pone en un `%TEMP%` y lo borra). Env vars del proceso son legibles por otro proceso
  admin/SYSTEM. ¿Aceptable para v1, o **endurecer** (el wizard escribe a un archivo temporal con
  ACL en vez de env var)? Rec: aceptable v1 (mismo nivel de exposición que hoy), endurecer en v2.

## CONSTRUIDO — 2026-07-23 (propose-only, sin commit/deploy)
Archivos:
- **`WatcherBrain/WinConfigWizard.ps1`** (nuevo) — el wizard WinForms parametrizado `-Mode Install|Uninstall`.
- **`WatcherBrain/RunWizardHidden.vbs`** (nuevo) — launcher oculto (wscript → powershell hidden; el wizard se auto-eleva).
- **`Instalar.bat`** / **`Restaurar.bat`** (nuevos, raíz) — entradas de doble-clic (install / uninstall).
- **`install.ps1`** — el bootstrapper ahora lanza el wizard (fallback al .bat si falta).
- **`BackToNormal.bat` / `InstallWatcher.bat`: SIN CAMBIOS** (el "no moverlo" respetado — el uninstall se
  maneja por el pipe de stdin en memoria).

Revisión de seguridad (pase adversarial): código maestro **nunca** en línea de comando ni en disco
(install=env var; uninstall=pipe stdin en memoria); `set /p` con stdin redirigido no eco el valor al log;
el log temporal se borra; scrub del textbox + $master tras el handoff; `proc.Start()` con try/catch →
pantalla de error limpia; `$matches` (automática) renombrada; `-Mode` con ValidateSet.

**Estado de verificación:** parsea OK bajo **pwsh 7.6** (Mac) e `install.ps1` también. Escrito para
compat **5.1**. PENDIENTE: (a) parse-check bajo el 5.1 real + load de WinForms en HW — **TEST 01 quedó
offline** al intentarlo; (b) **verificación VISUAL/interactiva del wizard = requiere escritorio real
(logon físico o VNC), NO se puede por SSH** (sin window station). Bundle v1.0.16 reconstruido con los 4
archivos nuevos (sha `0caa5c71…`).

## Verificación (cuando se retome)
- E2E en TEST 01 por SSH: el launcher muestra el wizard (0 consola), Instalar → barra [n/8] →
  Listo; máquina sana (1 node, filtrando, hash presente). Inyectar un fallo → «No se completó»
  + máquina desarmada (internet normal). Fallback consola si se fuerza WinForms a fallar.
- Ojo físico: la ventana se ve en el logon interactivo (por SSH no hay desktop).
