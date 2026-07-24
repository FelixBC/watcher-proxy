@echo off
REM abracadabra — MUESTRA todo lo que el instalador dejo oculto en esta carpeta
REM (WatcherBrain, InstallWatcher, BackToNormal, Restaurar, etc.) para poder verlo
REM y usarlo. Correr "cadabra.bat" (que aparece al lado) lo vuelve a ocultar todo,
REM dejando visible solo este "abracadabra". Nada de esto desinstala ni cambia el
REM filtro: solo hace visibles los archivos (BackToNormal sigue pidiendo su codigo).
REM Use attrib with a wildcard, NOT a FOR loop: cmd's `for %%F in (*)` SKIPS files
REM that carry the Hidden or System attribute — which are exactly the ones we need
REM to reveal — so the old FOR version could never un-hide anything. attrib with a
REM wildcard processes hidden/system files too. /d also un-hides the WatcherBrain dir.
attrib -h -s "%~dp0*" /d >nul 2>&1
