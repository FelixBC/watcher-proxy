╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║                WATCHER – QUICK CLIENT GUIDE                  ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝


PACKAGE STRUCTURE (VISUAL)
═══════════════════════════════════════════════════════════════

You should see this layout:

  <Your folder>
  ├─ abracadabra.bat        (hide the Watcher folder)
  ├─ cadabra.bat            (unhide the Watcher folder)
  └─ Watcher\
     ├─ InstallWatcher.bat  (install / enable)
     ├─ BackToNormal.bat    (remove / disable)
     ├─ whitelist.txt       (allowed websites)
     ├─ README.txt          (this file)
     └─ WatcherBrain\       (internal engine: proxy + scripts + node.exe)


INSTALL (ONE TIME PER PC)
═══════════════════════════════════════════════════════════════

1) Copy the package to the PC.

2) Open the folder named "Watcher" and run:
   → InstallWatcher.bat

3) Recommended: run as Administrator
   → Right‑click InstallWatcher.bat → Run as administrator

   Why admin helps:
   - Enables the automatic print cleanup (kept printed documents).
   - Creates scheduled tasks that must run as SYSTEM.
   - Allows adding antivirus exclusions (Defender / other AV).

4) Done.
   The proxy is set automatically to 127.0.0.1:8080 and starts on every logon.
   You do NOT need to configure the browser by hand.


IMPORTANT FILES (WHAT THEY DO)
═══════════════════════════════════════════════════════════════

Inside the "Watcher" folder:

- InstallWatcher.bat
  Installs Watcher on the PC (proxy + auto-start + optional print cleanup).

- BackToNormal.bat
  Removes Watcher from the PC (internet back to normal).
  IMPORTANT: it opens TWO windows on purpose:
  - Window 1 (normal user): turns OFF proxy for the current user (restores internet).
  - Window 2 (admin prompt): removes SYSTEM scheduled tasks + All Users startup items.
    Click "Yes" on the admin prompt to finish removal.

  Why two windows?
  - Proxy settings are per-user (HKCU), so Window 1 must run as the user who browses.
  - Scheduled tasks are system-level, so Window 2 needs admin rights to delete them.

  Normal click behavior:
  - Just double-click BackToNormal.bat.
  - Do NOT right-click → Run as administrator as the first step (it won’t fix the browsing user).
  - Let it prompt for admin by itself (Window 2) to finish removing tasks.

- whitelist.txt
  List of allowed websites (one per line, e.g. google.com).
  Only sites listed here will work when Watcher is ON.
  You can edit it anytime; changes apply automatically.

Next to the "Watcher" folder (one level up):

- abracadabra.bat
  Hides the "Watcher" folder in Explorer (does NOT stop the proxy).

- cadabra.bat
  Unhides the "Watcher" folder.


SUMMARY
═══════════════════════════════════════════════════════════════

Install on a PC     → Watcher\InstallWatcher.bat (admin recommended)
Allow a website     → Edit Watcher\whitelist.txt and save
Remove Watcher      → Watcher\BackToNormal.bat (accept the admin prompt window)
Hide the folder     → abracadabra.bat
Show the folder     → cadabra.bat


╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║               WATCHER – GUÍA RÁPIDA (ESPAÑOL)                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝


ESTRUCTURA DEL PAQUETE (VISUAL)
═══════════════════════════════════════════════════════════════

Debes ver esta estructura:

  <Tu carpeta>
  ├─ abracadabra.bat        (oculta la carpeta Watcher)
  ├─ cadabra.bat            (muestra la carpeta Watcher)
  └─ Watcher\
     ├─ InstallWatcher.bat  (instalar / activar)
     ├─ BackToNormal.bat    (quitar / desactivar)
     ├─ whitelist.txt       (páginas permitidas)
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
   - Activa la limpieza automática de impresión (documentos impresos guardados).
   - Crea tareas programadas que deben ejecutarse como SYSTEM.
   - Permite agregar exclusiones en el antivirus (Defender / otro AV).

4) Listo.
   El proxy se configura automáticamente en 127.0.0.1:8080 y se inicia en cada inicio de sesión.
   NO necesitas configurar el navegador manualmente.


ARCHIVOS IMPORTANTES (PARA QUÉ SIRVEN)
═══════════════════════════════════════════════════════════════

Dentro de la carpeta "Watcher":

- InstallWatcher.bat
  Instala Watcher en la PC (proxy + auto-inicio + limpieza opcional de impresión).

- BackToNormal.bat
  Quita Watcher de la PC (internet vuelve a la normalidad).
  IMPORTANTE: abre DOS ventanas a propósito:
  - Ventana 1 (usuario normal): APAGA el proxy para el usuario actual (restaura internet).
  - Ventana 2 (permiso de administrador): elimina las tareas SYSTEM y el inicio para "Todos los usuarios".
    Haz clic en "Sí" cuando pida permisos para terminar.

  ¿Por qué dos ventanas?
  - La configuración del proxy es por usuario (HKCU), por eso la Ventana 1 debe correr con el usuario que navega.
  - Las tareas programadas son del sistema, por eso la Ventana 2 necesita permisos de administrador para borrarlas.

  Comportamiento correcto (clic normal):
  - Solo haz doble clic en BackToNormal.bat.
  - NO hagas primero: clic derecho → Ejecutar como administrador (no arregla el usuario que navega).
  - Deja que pida permisos solo (Ventana 2) para terminar de borrar las tareas.

- whitelist.txt
  Lista de páginas permitidas (una por línea, por ejemplo: google.com).
  Solo las páginas en esta lista funcionarán cuando Watcher esté ACTIVO.
  Puedes editarla cuando quieras; los cambios se aplican automáticamente.

Al lado de la carpeta "Watcher" (un nivel arriba):

- abracadabra.bat
  Oculta la carpeta "Watcher" en el Explorador (NO detiene el proxy).

- cadabra.bat
  Vuelve a mostrar la carpeta "Watcher".


RESUMEN
═══════════════════════════════════════════════════════════════

Instalar en una PC      → Watcher\InstallWatcher.bat (admin recomendado)
Permitir una página     → Editar Watcher\whitelist.txt y guardar
Quitar Watcher          → Watcher\BackToNormal.bat (aceptar la ventana de permisos)
Ocultar la carpeta      → abracadabra.bat
Mostrar la carpeta      → cadabra.bat
