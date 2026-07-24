@echo off
REM abracadabra — MUESTRA todo lo que el instalador dejo oculto en esta carpeta
REM (WatcherBrain, InstallWatcher, BackToNormal, Restaurar, etc.) para poder verlo
REM y usarlo. Correr "cadabra.bat" (que aparece al lado) lo vuelve a ocultar todo,
REM dejando visible solo este "abracadabra". Nada de esto desinstala ni cambia el
REM filtro: solo hace visibles los archivos (BackToNormal sigue pidiendo su codigo).
for /d %%D in ("%~dp0*") do attrib -h -s "%%D" >nul 2>&1
for %%F in ("%~dp0*") do attrib -h -s "%%F" >nul 2>&1
