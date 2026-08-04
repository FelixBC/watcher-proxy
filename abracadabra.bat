@echo off
REM abracadabra — MUESTRA todo lo que el instalador dejo oculto en esta carpeta
REM (WatcherBrain, Install.exe, Uninstall.exe, InstallWatcher, BackToNormal, etc.)
REM para poder verlo y usarlo. Correr "cadabra.bat" (que aparece al lado) lo vuelve
REM a ocultar todo, dejando visible solo este "abracadabra". Nada de esto desinstala
REM ni cambia el filtro: solo hace visibles los archivos (Uninstall.exe / BackToNormal
REM siguen pidiendo su codigo).
REM Use attrib with a wildcard, NOT a FOR loop: cmd's `for %%F in (*)` SKIPS files
REM that carry the Hidden or System attribute — which are exactly the ones we need
REM to reveal — so the old FOR version could never un-hide anything. attrib with a
REM wildcard processes hidden/system files too. /d also un-hides the WatcherBrain dir.
attrib -h -s "%~dp0*" /d >nul 2>&1
