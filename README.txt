╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║                WATCHER – CLIENT GUIDE                        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝


WHAT THIS IS
═══════════════════════════════════════════════════════════════

Watcher restricts a Windows PC's internet access to an approved list of
websites (whitelist.txt), while still allowing remote-support tools
(UltraViewer) to connect in. It also clears the Windows print spool once a
day so old, already-paid ticket jobs can't be reprinted and claimed again.

It is built to be installed once and then left alone. These machines are
typically set up and then unattended — nobody is monitoring them locally,
support only happens through UltraViewer.


DESIGN RULES (READ BEFORE CHANGING ANYTHING)
═══════════════════════════════════════════════════════════════

These are load-bearing. If you're editing the scripts, keep these true:

1. INTERNET NEVER STOPS, EVEN IF THE FILTER DOES.
   If the proxy crashes, gets closed, or fails to start, Windows is switched
   back to normal unfiltered internet automatically and immediately — the
   person at the PC is never left offline. The filter comes back on its own
   within seconds once the proxy is healthy again (WatchdogLoop.ps1, every
   5 sec). Restriction is allowed to fail open; connectivity is not allowed
   to fail at all.

2. FILTERED AS FAST AS POSSIBLE AFTER BOOT, BUT NEVER BLOCKING BOOT.
   The proxy starts hidden at logon and again after resume from sleep. A
   Node-based port check (not PowerShell) is used at boot because it's
   several seconds faster on a cold machine — the goal is the filter being
   active before the user is doing anything real, without making them wait.

3. NO VISIBLE WINDOWS, NO PROMPTS, NO CONSOLE.
   Everything runs as a hidden scheduled task. A user should never see a
   terminal, a popup, or anything that invites them to close/investigate it.

4. UltraViewer (and remote-support traffic by raw IP) IS ALWAYS ALLOWED.
   UltraViewer is the default and only remote-support tool used on these
   machines. Its connections aren't always resolvable by hostname, so the
   proxy whitelists raw IP destinations broadly rather than trying to pin
   down UltraViewer's IP ranges exactly. This is intentional, not a gap —
   support reliability wins over narrowing this further.

5. THE PRINT SPOOL WIPE IS A FRAUD CONTROL, NOT HOUSEKEEPING.
   These are single-purpose ticket/receipt terminals. The daily wipe exists
   because employees were reprinting cached ticket jobs still sitting in
   the spool to claim payouts that were already paid out. If a machine ever
   also needs to print something else, this needs to be scoped to a specific
   printer — right now it clears the whole spool folder.

6. WHITELIST.TXT IS PER-MACHINE, NEVER OVERWRITE IT BLINDLY.
   Each installed PC's whitelist reflects what that specific business/site
   needs. Reinstalling or updating Watcher must not silently replace it.

7. ADMIN RIGHTS UNLOCK THE FULL FEATURE SET, BUT AREN'T STRICTLY REQUIRED.
   Without admin: the proxy still runs and filters. With admin: antivirus
   exclusion, the daily print-spool cleanup task, and system-level scheduled
   tasks also get installed. Always prefer "Run as administrator."


PACKAGE STRUCTURE (VISUAL)
═══════════════════════════════════════════════════════════════

  <Your folder>
  ├─ abracadabra.bat        (hide the Watcher folder)
  ├─ cadabra.bat            (unhide the Watcher folder)
  └─ Watcher\
     ├─ InstallWatcher.bat  (install / enable)
     ├─ BackToNormal.bat    (remove / disable)
     ├─ whitelist.txt       (allowed websites — per-machine, edit freely)
     ├─ README.txt          (this file)
     └─ WatcherBrain\       (internal engine: proxy + scripts + node.exe)


INSTALL (ONE TIME PER PC)
═══════════════════════════════════════════════════════════════

1) Copy the package to the PC.

2) Open the folder named "Watcher" and run:
   → InstallWatcher.bat

3) Recommended: run as Administrator
   → Right-click InstallWatcher.bat → Run as administrator

   Why admin helps:
   - Enables the automatic print cleanup (kept printed documents).
   - Creates scheduled tasks that must run as SYSTEM.
   - Allows adding antivirus exclusions (Defender / other AV) — without
     this, antivirus can quietly delete the proxy and nobody will be there
     to notice.

4) Done.
   The proxy is set automatically to 127.0.0.1:8080 and starts on every
   logon and every resume from sleep. You do NOT need to configure the
   browser by hand, and you do not need to come back to check on it.


IMPORTANT FILES (WHAT THEY DO)
═══════════════════════════════════════════════════════════════

Inside the "Watcher" folder:

- InstallWatcher.bat
  Installs Watcher on the PC (proxy + auto-start + antivirus exclusion +
  print cleanup, in that order, so nothing races on first boot).

- BackToNormal.bat
  Removes Watcher from the PC (internet back to normal).
  IMPORTANT: it opens TWO windows on purpose:
  - Window 1 (normal user): stops the watchdog, turns OFF proxy for the
    current user (restores internet).
  - Window 2 (admin prompt): removes SYSTEM scheduled tasks + All Users
    startup items. Click "Yes" on the admin prompt to finish removal.

  Why two windows?
  - Proxy settings are per-user (HKCU), so Window 1 must run as the user
    who browses.
  - Scheduled tasks are system-level, so Window 2 needs admin rights to
    delete them. The watchdog is killed in Window 1 first — otherwise it
    would just turn the proxy back on a few seconds later.

  Normal click behavior:
  - Just double-click BackToNormal.bat.
  - Do NOT right-click → Run as administrator as the first step (it won't
    fix the browsing user).
  - Let it prompt for admin by itself (Window 2) to finish removing tasks.

- whitelist.txt
  List of allowed websites (one per line, e.g. google.com).
  Only sites listed here will work when Watcher is ON. UltraViewer and
  raw-IP connections work regardless of this list (see rule 4 above).
  You can edit it anytime; changes apply automatically within ~60 sec, or
  immediately on save.

Next to the "Watcher" folder (one level up):

- abracadabra.bat
  Hides the "Watcher" folder in Explorer (does NOT stop the proxy).

- cadabra.bat
  Unhides the "Watcher" folder.


IF SOMETHING GOES WRONG
═══════════════════════════════════════════════════════════════

- No internet at all:
  Run WatcherBrain\RestoreInternetNow.bat. This switches Windows back to
  normal internet immediately without needing the proxy to be working.
  (In practice this should self-heal within 5 seconds on its own.)

- Everything is blocked:
  Check whitelist.txt — make sure the sites are listed correctly.

- Proxy stopped working / antivirus keeps removing it:
  Run InstallWatcher.bat as Administrator again (re-adds the AV exclusion).
  See WatcherBrain\FIX_ANTIVIRUS_REMOVING_PROXY.txt for details.


SUMMARY
═══════════════════════════════════════════════════════════════

Install on a PC     → Watcher\InstallWatcher.bat (admin recommended)
Allow a website      → Edit Watcher\whitelist.txt and save
Remove Watcher       → Watcher\BackToNormal.bat (accept the admin prompt window)
Restore internet now → WatcherBrain\RestoreInternetNow.bat
Hide the folder       → abracadabra.bat
Show the folder       → cadabra.bat


╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║               WATCHER – GUÍA DEL CLIENTE (ESPAÑOL)           ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝


QUÉ ES ESTO
═══════════════════════════════════════════════════════════════

Watcher restringe el acceso a internet de una PC con Windows a una lista
de páginas aprobadas (whitelist.txt), permitiendo siempre que herramientas
de soporte remoto (UltraViewer) puedan conectarse. También limpia el spool
de impresión una vez al día para que no se puedan reimprimir tickets ya
pagados y cobrarlos de nuevo.

Está pensado para instalarse una vez y dejarse funcionando solo. Estas PCs
normalmente se configuran y luego quedan sin supervisión local — el soporte
solo se hace por UltraViewer.


REGLAS DE DISEÑO (LEER ANTES DE CAMBIAR ALGO)
═══════════════════════════════════════════════════════════════

Estas reglas son la base del programa. Si vas a editar los scripts, no las
rompas:

1. EL INTERNET NUNCA SE DETIENE, AUNQUE EL FILTRO SÍ.
   Si el proxy se cae, se cierra o no arranca, Windows vuelve automática e
   inmediatamente a internet normal sin filtro — la persona en la PC nunca
   se queda sin internet. El filtro vuelve solo en segundos cuando el proxy
   está sano otra vez (WatchdogLoop.ps1, cada 5 seg). La restricción puede
   fallar; la conexión a internet no puede fallar nunca.

2. FILTRADO LO MÁS RÁPIDO POSIBLE DESPUÉS DE ENCENDER, SIN BLOQUEAR EL INICIO.
   El proxy arranca oculto al iniciar sesión y también al reanudar de
   suspensión. Se usa una verificación de puerto basada en Node (no
   PowerShell) porque es varios segundos más rápida en frío — la meta es
   que el filtro esté activo antes de que el usuario haga algo real, sin
   hacerlo esperar.

3. SIN VENTANAS VISIBLES, SIN AVISOS, SIN CONSOLA.
   Todo corre como tarea programada oculta. El usuario nunca debe ver una
   terminal, un popup, ni nada que lo invite a cerrarlo o investigarlo.

4. UltraViewer (y el tráfico de soporte remoto por IP directa) SIEMPRE ESTÁ PERMITIDO.
   UltraViewer es la única herramienta de soporte remoto usada en estas
   máquinas. Sus conexiones no siempre se pueden identificar por nombre de
   dominio, así que el proxy permite direcciones IP directas de forma
   amplia en vez de intentar acotar los rangos exactos de UltraViewer. Esto
   es intencional, no un descuido — la confiabilidad del soporte pesa más
   que restringir esto todavía más.

5. LA LIMPIEZA DEL SPOOL DE IMPRESIÓN ES UN CONTROL DE FRAUDE, NO LIMPIEZA NORMAL.
   Estas son máquinas de un solo propósito (tickets/recibos). La limpieza
   diaria existe porque empleados reimprimían trabajos de impresión que
   quedaban guardados en el spool para cobrar tickets que ya habían sido
   pagados. Si alguna máquina también necesita imprimir otra cosa, esto hay
   que limitarlo a una impresora específica — hoy limpia todo el spool.

6. whitelist.txt ES POR MÁQUINA, NUNCA SOBRESCRIBIRLO SIN CUIDADO.
   La whitelist de cada PC instalada refleja lo que ese negocio/sitio
   específico necesita. Reinstalar o actualizar Watcher no debe reemplazarla
   en silencio.

7. LOS PERMISOS DE ADMINISTRADOR DESBLOQUEAN TODO, PERO NO SON OBLIGATORIOS.
   Sin admin: el proxy funciona y filtra igual. Con admin: se agregan la
   exclusión de antivirus, la tarea diaria de limpieza de spool y las
   tareas programadas de sistema. Siempre preferir "Ejecutar como
   administrador".


ESTRUCTURA DEL PAQUETE (VISUAL)
═══════════════════════════════════════════════════════════════

  <Tu carpeta>
  ├─ abracadabra.bat        (oculta la carpeta Watcher)
  ├─ cadabra.bat            (muestra la carpeta Watcher)
  └─ Watcher\
     ├─ InstallWatcher.bat  (instalar / activar)
     ├─ BackToNormal.bat    (quitar / desactivar)
     ├─ whitelist.txt       (páginas permitidas — por máquina, editable)
     ├─ README.txt          (este archivo)
     └─ WatcherBrain\       (motor interno: proxy + scripts + node.exe)


INSTALACIÓN (UNA VEZ POR CADA PC)
═══════════════════════════════════════════════════════════════

1) Copia el paquete a la PC.

2) Abre la carpeta llamada "Watcher" y ejecuta:
   → InstallWatcher.bat

3) Recomendado: ejecutar como Administrador
   → Clic derecho en InstallWatcher.bat → Ejecutar como administrador

   ¿Por qué ayuda el modo administrador?
   - Activa la limpieza automática de impresión (documentos impresos
     guardados).
   - Crea tareas programadas que deben ejecutarse como SYSTEM.
   - Permite agregar exclusiones en el antivirus (Defender / otro AV) — sin
     esto, el antivirus puede borrar el proxy en silencio y no habrá nadie
     ahí para notarlo.

4) Listo.
   El proxy se configura automáticamente en 127.0.0.1:8080 y se inicia en
   cada inicio de sesión y cada reanudación de suspensión. NO necesitas
   configurar el navegador manualmente, ni volver a revisarlo.


ARCHIVOS IMPORTANTES (PARA QUÉ SIRVEN)
═══════════════════════════════════════════════════════════════

Dentro de la carpeta "Watcher":

- InstallWatcher.bat
  Instala Watcher en la PC (proxy + auto-inicio + exclusión de antivirus +
  limpieza de impresión, en ese orden, para que nada compita en el primer
  arranque).

- BackToNormal.bat
  Quita Watcher de la PC (internet vuelve a la normalidad).
  IMPORTANTE: abre DOS ventanas a propósito:
  - Ventana 1 (usuario normal): detiene el watchdog, APAGA el proxy para
    el usuario actual (restaura internet).
  - Ventana 2 (permiso de administrador): elimina las tareas SYSTEM y el
    inicio para "Todos los usuarios". Haz clic en "Sí" cuando pida permisos
    para terminar.

  ¿Por qué dos ventanas?
  - La configuración del proxy es por usuario (HKCU), por eso la Ventana 1
    debe correr con el usuario que navega.
  - Las tareas programadas son del sistema, por eso la Ventana 2 necesita
    permisos de administrador para borrarlas. El watchdog se mata primero
    en la Ventana 1 — si no, volvería a encender el proxy en segundos.

  Comportamiento correcto (clic normal):
  - Solo haz doble clic en BackToNormal.bat.
  - NO hagas primero: clic derecho → Ejecutar como administrador (no
    arregla el usuario que navega).
  - Deja que pida permisos solo (Ventana 2) para terminar de borrar las
    tareas.

- whitelist.txt
  Lista de páginas permitidas (una por línea, por ejemplo: google.com).
  Solo las páginas en esta lista funcionarán cuando Watcher esté ACTIVO.
  UltraViewer y las conexiones por IP directa funcionan sin importar esta
  lista (ver regla 4 arriba).
  Puedes editarla cuando quieras; los cambios se aplican en ~60 seg, o de
  inmediato al guardar.

Al lado de la carpeta "Watcher" (un nivel arriba):

- abracadabra.bat
  Oculta la carpeta "Watcher" en el Explorador (NO detiene el proxy).

- cadabra.bat
  Vuelve a mostrar la carpeta "Watcher".


SI ALGO SALE MAL
═══════════════════════════════════════════════════════════════

- No hay internet en absoluto:
  Ejecuta WatcherBrain\RestoreInternetNow.bat. Esto pone internet normal de
  inmediato sin necesitar que el proxy esté funcionando.
  (En la práctica esto debería auto-repararse solo en 5 segundos.)

- Todo está bloqueado:
  Revisa whitelist.txt — asegúrate de que las páginas estén bien escritas.

- El proxy deja de funcionar / el antivirus lo sigue eliminando:
  Ejecuta InstallWatcher.bat como Administrador otra vez (vuelve a agregar
  la exclusión de antivirus). Ver WatcherBrain\FIX_ANTIVIRUS_REMOVING_PROXY.txt.


RESUMEN
═══════════════════════════════════════════════════════════════

Instalar en una PC       → Watcher\InstallWatcher.bat (admin recomendado)
Permitir una página      → Editar Watcher\whitelist.txt y guardar
Quitar Watcher           → Watcher\BackToNormal.bat (aceptar la ventana de permisos)
Restaurar internet ya    → WatcherBrain\RestoreInternetNow.bat
Ocultar la carpeta       → abracadabra.bat
Mostrar la carpeta       → cadabra.bat
