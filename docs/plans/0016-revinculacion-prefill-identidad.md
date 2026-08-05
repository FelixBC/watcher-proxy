# 0016 — Re-vinculación sin re-teclear la identidad (pre-fill + banca opcional)

**Estado:** CONSTRUIDO + revisado + write verificado en HW 2026-08-05. v1.0.40. NO commiteado (git de Felix). /descargar por refrescar; OTA pendiente de Felix.
**Repo:** watcher-proxy (`WatcherBrain/AskIdentity.ps1`). Cambio de agente → VERSION 1.0.39→1.0.40.
**Origen:** hilo 2026-08-05 tras validar la re-vinculación (plan 0010 del hub). Al re-enrolar, el instalador **forzaba re-teclear el código de banca** (nombre/zona ya eran opcionales) aunque el dato ya está en el dashboard.

## Problema (una frase)
En una re-vinculación (re-correr `InstallWatcher.bat` en la carpeta) el instalador obliga a re-teclear el código de banca, que ya está en el dashboard; Nelson debería solo poner el código maestro.

## Qué se hizo (solo `AskIdentity.ps1` — la ruta de consola que usa el re-run)
- **Pre-fill:** lee los `machine-name/zone/code.txt` existentes (con `-Force`, están Hidden+System por el disfraz) y los pone como valor por defecto en los popups → editable.
- **Banca opcional en re-vinculación:** si `machine-code.txt` ya tiene valor (`$bancaAlreadySet`), el banca deja de ser requerido (pre-rellenado, se confirma o edita). En instalación NUEVA sigue **requerido** (bucle 3 intentos + hard-fail). Igual en la ruta desatendida (env).
- **Set-Field helper:** escribe los identity files limpiando +h+s primero + `Set-Content -Force` — sin esto, sobreescribir un archivo Hidden+System **reventaba** (misma clase EPERM que el repo documenta para Node) y abortaba con un error engañoso de "falta código maestro". **Verificado en la test PC real:** `SETFIELD_OK=True`.
- **`$bancaProvided` sembrado de `$bancaAlreadySet`:** el mensaje de error final no miente si un popup falla.
- Nunca borra un valor existente: escribe solo si se tecleó algo no vacío; en blanco conserva.

## No-objetivos / límites conocidos
- **El wizard GUI (`WinConfigWizard.ps1`) NO recibe el cambio.** Es la ruta de instalación NUEVA (sin archivos que pre-rellenar → banca requerido, correcto). Una re-vinculación por GUI (poco común: el ayudante rehúsa carpetas existentes) seguiría forzando el banca. Follow-up si hiciera falta.
- **Solo aplica cuando la máquina RE-ENROLA** (sin `hub-credential.json` local). Con credencial presente, `registerIfNeeded` no llama al hub — pero ese no es el caso de re-vinculación (la credencial se borró en el panel).
- No toca el golden-rule, ni el 409, ni el resto del enroll.

## Verificación
- `pwsh` parse: OK. Revisor separado (sonnet): 2 CONFIRMED (write sin -Force → **arreglado + HW-verified**; wizard no cubierto → documentado), 2 consideraciones (resueltas/no aplican).
- HW en test PC: sobrescribir Hidden+System con el mecanismo Set-Field = OK; leer oculto = OK.
- Pendiente: E2E completo en la test PC (re-vinculación con banca pre-rellenado, solo código maestro) tras subir 1.0.40.

## Release
Agente → bump VERSION (hecho) → build bundle → copy a fleet/public → `vercel --prod` (/descargar para instalaciones nuevas) → **OTA `publish-agent.mjs` (Felix, secret)** para las máquinas existentes.
