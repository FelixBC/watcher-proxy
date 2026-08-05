# 0014 — Ayudante de instalación (bootstrapper descargable) + higiene de carpeta

**Estado:** LOCK APROBADO por Felix ("va"). Q1/Q3 cerradas (abajo). Pasa a research→build.
**Alineado en:** artefacto `/aligned` (decisiones A–E cerradas). Este doc es el lock.

### Decisiones finales (Q1–Q4)
- **Q1 ✓ — Formato:** el ayudante es un **`.bat` doble-clicable** (invoca PowerShell, sin compilar).
- **Q2 ✓ — Reuso (revisado green-loop Obj 4/5):** el ayudante es **auto-contenido** — adapta la
  ESTRUCTURA probada de `install.ps1` (eleva → descarga zip → crea+endurece carpeta → extrae →
  entrega al wizard), pero con su lógica embebida y URLs reales. **NO baja `install.ps1` en runtime**
  (evita 2º fetch + trampa de placeholders). **`install.ps1` queda intacto** — la colisión-rechazo NO
  se hornea en el bootstrapper compartido (que es re-ejecutable para reparar).
- **Q3 ✓ — AC8 (higiene de raíz): DIFERIDA** a un cambio propio (fuera del alcance de 0014). Es la
  parte más riesgosa (roza el contrato OTA/VERSION) y de menor valor (el disfraz ya oculta todo). Ver
  no-objetivos.
- **Q4 ✓ — Borrado del ayudante (revisado green-loop Obj 3):** el ayudante fija
  `WATCHER_BOOTSTRAP_PATH` (su propia ruta) y lanza el wizard con esa env. El **borrado lo hace
  `InstallWatcher.bat`** en el éxito (cubre TODOS los flujos: wizard, fallback consola, bundle viejo);
  el **wizard solo muestra el aviso** en pantalla (corre oculto, no puede avisar él el borrado).

### Revisiones del green-loop (round 1) — dobladas al lock
1. **Elevación (Obj 1, bloqueante):** el **ayudante se auto-eleva PRIMERO**; así el resto corre admin
   y no se pierden parámetros en un relanzamiento. Se prueba en no-admin (que aterrice en
   `C:\EPSON TMM20II\WinConfig` y con la env fijada).
2. **Colisión fail-open (Obj 2):** ver AC5/AC6 — señal por proxy, normalizar-internet-antes, parar si
   el borrado falla.
3. **Borrado en InstallWatcher, aviso en wizard (Obj 3):** ver Q4.
4. **Ayudante auto-contenido (Obj 5):** ver Q2.

---

## Problema (una frase)

Instalar el Watcher a mano desde `/descargar` deja que Nelson (no técnico) elija dónde
extraer el zip — y una extracción a la carpeta equivocada (o una instalación a medias, p. ej.
`node.exe` que no se descargó) deja la instalación **rota**: la verificación de código del
uninstall corre `node` y si `node` no está, **ningún** código verifica → "código incorrecto"
pase lo que pase. Además, tras desinstalar los archivos quedan **ocultos** y en la raíz conviven
archivos que Nelson podría romper sin querer.

> **Corrección de premisa (green-loop round 1):** el fallo NO era "espacios/paréntesis rompen
> `node`". Un **espacio** es seguro (todos los sitios que llaman node están entre comillas;
> Windows mismo usa `C:\Program Files`). Solo un **metacarácter** rompe cmd — y los `)` de una
> carpeta `(2)` (descarga duplicada) traen ese `)`. La causa observada de "siempre incorrecto"
> fue la **instalación rota / `node` ausente**, no el path en sí. El valor del ayudante es la
> **colocación a prueba de tontos + un install bien formado** (sin variantes, sin metacaracteres,
> con `node` descargado), no "evitar espacios". La carpeta `C:\EPSON TMM20II\WinConfig` es segura.

## Contexto que ya existe (no reinventar)

- **`install.ps1`** ya es un bootstrapper hospedado: auto-eleva, descarga el bundle, **extrae a
  un path fijo `C:\WinConfig`**, y entrega a `InstallWatcher.bat`. El "ayudante" es esencialmente
  esta lógica probada, pero **descargable** (doble-clic), apuntando a `C:\EPSON TMM20II`, con
  manejo de colisión y auto-borrado.
- **Disfraz:** `InstallWatcher.bat` (L411-412) oculta `+h +s` todo menos `abracadabra.bat`.
- **`BackToNormal.bat` NO revela nada al final** (no hay `attrib -h -s`) → por eso quedan ocultos.
- **`VERSION` vive en la raíz** y lo leen `self-update.js` (`ROOT_DIR/VERSION`), `poll-hub.js`
  (`BRAIN_DIR/../VERSION`) y `build-winconfig-bundle.sh` → **mover VERSION rompe el OTA**.

## Criterios de aceptación (cada uno verificable)

1. Desde `/descargar`, Nelson baja **UN solo archivo** (el ayudante) y, con **doble-clic**, llega
   a una instalación completa **sin crear carpetas ni elegir rutas**; su única entrada es el código
   maestro (+ identidad) en el asistente. *(A, B)*
2. El ayudante **descarga el bundle**, crea `C:\EPSON TMM20II\`, lo mueve/extrae ahí (carpeta tope
   `WinConfig` → `C:\EPSON TMM20II\WinConfig`) y **lanza el instalador** solo. *(A, B, C)*
3. En una PC limpia, el flujo completo termina **igual que `install.ps1` hoy** (enrolada, filtrando,
   disfrazada) — mismo estado final, solo que en el path nuevo.
4. El **instalador borra el ayudante** de `Descargas` al terminar y **lo avisa en pantalla**; tras
   instalar, `Descargas` no tiene el ayudante. El borrado lo hace el **instalador**, no el ayudante
   (un proceso no se mata a sí mismo).
5. **Colisión — Watcher VIVO** (CUALQUIER señal de vida: una tarea programada `WinConfig` — incl. la
   base sin sufijo — **o** `node` corriendo desde la carpeta **o** el puerto obscuro escuchando): el
   ayudante **NO instala ni sobrescribe ni borra**; muestra "ya está instalado, desinstala primero
   con Uninstall.exe". La máquina sigue filtrando, intacta. *(E)*
6. **Colisión — carpeta MUERTA** (la carpeta existe pero **cero** señales de vida: ni tareas, ni node,
   ni puerto): el ayudante **normaliza internet primero** (seguro barato, regla de oro), luego borra
   la carpeta vieja e instala fresco en el mismo lugar. **Nunca** crea un `(2)` ni un nombre variante.
   Si el borrado falla (algo bloqueado) → **para y reporta**, no instala encima.
7. Tras un uninstall exitoso, `BackToNormal.bat` **revela** (`attrib -h -s`) los archivos de la carpeta
   — Nelson los ve **sin** correr `abracadabra`. El revelar va **después** de restaurar internet
   (no reordena la secuencia de la regla de oro).
8. **~~Higiene de raíz~~ — DIFERIDA (Q3), fuera del alcance de 0014.** Va en un cambio propio con
   análisis por-archivo de consumidores; `VERSION` nunca se mueve (contrato OTA).
9. **Reinstalar en la misma PC** cuya fila del panel sigue existiendo → el enroll da **409**; el
   instalador **lo detecta y le dice claro a Nelson que borre la máquina del panel primero** (parar y
   guiar). **Sin** re-enrol silencioso.

## No-objetivos (la cerca anti-scope-creep)

- **Auto-curado / re-enrol silencioso** (idea F de 0005) — **DESCARTADO**: un intento de quitar el
  Watcher debe quedar **visible** (alerta de tamper) y manejarlo Nelson; auto-curarlo taparía el aviso.
- **Reemplazo en caliente** de un Watcher vivo (desinstalar+reinstalar de un tirón).
- Crear cualquier carpeta variante `(2)` / renombrada.
- **Mover `VERSION`** fuera de la raíz (rompe el OTA).
- **Higiene de raíz / mover archivos a WatcherBrain** (AC8) — diferida a un cambio propio (Q3).
- Cambiar cómo se teclea el código maestro (Nelson lo sigue tecleando — es la seguridad).
- Cambiar el anti-hijack/enroll (409): se **consume**, no se toca.

## Contratos y áreas con ADR que se tocan

- **Regla de oro** (`BackToNormal.bat`, marcado golden-rule-crítico en CLAUDE.md): el revelar es
  post-teardown (internet ya restaurado) → **debe** verificarse que NO reordena la secuencia
  fail-open. *Extiende, no cambia el orden.*
- **OTA / `VERSION`**: `VERSION` se queda en la raíz. La higiene de raíz (AC8) **no** puede mover
  ningún archivo que una ruta OTA lea por path de raíz. **Superficie de riesgo.**
- **Disfraz**: el ocultar en install no cambia; el revelar en uninstall es nuevo; AC8 cambia el
  layout sobre el que opera el disfraz.
- **Enroll / anti-hijack (409)**: se consume (el instalador guía), no se modifica.
- **`/descargar`** (watcher-fleet): ahora sirve **un archivo adicional** (el ayudante) junto al zip.
- **Path de instalación fijo**: hoy `install.ps1` fija `C:\WinConfig`; el ayudante fija
  `C:\EPSON TMM20II`. Quedan **dos** bootstrappers con dos destinos.

## Engranaje recomendado (a confirmar por Felix)

**FULL-ORCHESTRATOR.** Es multi-área (scripts del agente en watcher-proxy + página en watcher-fleet)
y toca **varias superficies de riesgo** (regla de oro en BackToNormal, contrato OTA/VERSION, disfraz,
enroll). Requiere revisor separado + verificación E2E en la test PC. *(Sesgo a escalar: hay riesgo.)*

## Preguntas abiertas (cerrar antes de construir)

- **Q1 — Formato del ayudante.** `.bat` doble-clicable (invoca PowerShell; sin compilar) vs `.exe`
  con icono profesional (como `Install.exe`, hay que compilar). **Rec:** empezar con `.bat` por
  simpleza; un `.exe` con icono se puede añadir después. *(Bifurcación real — tu llamada.)*
- **Q2 — ¿Reusar `install.ps1` o script nuevo?** **Rec:** adaptar la lógica probada de `install.ps1`
  (descarga+extrae+eleva+entrega) parametrizando el path destino, en vez de escribir de cero.
  ¿Mantener `install.ps1` (C:\WinConfig, flujo pegar) **y** el ayudante compartiendo lógica, o
  converger a uno? **Rec:** mantener ambos, lógica compartida.
- **Q3 — Alcance de AC8 (higiene de raíz).** Cada archivo a mover necesita análisis de sus
  consumidores. `VERSION` se queda (OTA). **Rec conservadora:** mover solo lo claramente seguro
  (analizar `machine-*.txt`, y si `InstallWatcher.bat` puede irse a WatcherBrain tras instalar); si
  el análisis por-archivo se complica, **AC8 se difiere** a un cambio propio. *(Es la parte más
  riesgosa y la de menor prioridad — el disfraz ya oculta todo igual.)*
- **Q4 — Cómo el instalador encuentra/borra el ayudante en Descargas.** **Rec:** el ayudante pasa su
  propia ruta a `InstallWatcher.bat` (variable de entorno, p. ej. `WATCHER_BOOTSTRAP_PATH`), que la
  borra al terminar con éxito + avisa. *(Detalle de diseño, no bifurcación de producto.)*

## Al aprobar

Con el "va" de Felix (y respuesta a Q1/Q3), esto pasa a research → solve → decompose →
implement (worktrees) → verify E2E en la test PC. Cualquier desvío de este lock = **parar y
reportar**, nunca expandir en silencio.
