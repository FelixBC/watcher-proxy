# ADR 0001 — Relajar "puerto = candado de instancia única" durante el cutover de update

- **Estado:** Aceptado (2026-07-25, Felix).
- **Contexto de la decisión:** plan 0007 (OTA sin hueco de filtro / blue-green con hogar fijo).
- **Primer ADR del repo** — establece la forma (Contexto / Decisión / Consecuencias) para los que sigan.

## Contexto

Este repo usa un invariante fuerte: **el puerto de escucha ES el candado de instancia única.** Hay
exactamente un proxy porque solo uno puede bindear el puerto obscuro del hogar (`:49732`); el
thundering-herd de arranques al logon se resuelve solo (los perdedores hacen `EADDRINUSE → exit(0)` en
`proxy-server.js`). El plan **0006 marcó explícitamente como non-goal**: *"NO cambiar el modelo de lock
de instancia única (puerto = lock)"*.

Pero el modelo actual **mata el proxy viejo antes** de que el nuevo escuche. En cada update OTA exitoso,
el proxy nuevo arranca en frío (~60–90s, node re-escaneado por Defender sobre el árbol recién swapeado),
y durante ese arranque el filtro queda **apagado** (fail-open: internet sí, filtro no). Para un producto
cuya única función es filtrar, ese hueco de ~60–90s por update es un agujero real.

El plan 0007 lo cierra con el patrón blue-green: levantar el proxy nuevo en un **puerto temporal B**
mientras el viejo **sigue filtrando en el hogar A**, cambiar Windows a B **solo cuando B ya escucha**,
matar A, y volver al hogar. Eso implica, inevitablemente, **dos proxies vivos** durante la ventana del
cutover — lo que el invariante "un puerto ⇒ un proxy" prohíbe.

## Decisión

Aceptamos **relajar el invariante "un puerto ⇒ un proxy" ÚNICAMENTE durante la ventana acotada del
cutover de un update**, bajo estas condiciones (todas obligatorias):

1. **Gateado por `updating.flag`** (con el stale-guard de 0006): mientras el flag existe, TODAS las
   capas del watchdog se paran — ninguna arranca un tercer proxy durante el cutover.
2. **Estado estable intacto:** fuera del cutover, exactamente **un** proxy, en el hogar canónico
   `:49732`. La relajación es transitoria, no permanente.
3. **Hogar fijo, sin drift:** B es un andamio transitorio; el proxy **siempre vuelve al hogar**. El pool
   de puertos es **fijo y elegido en install** (no búsqueda random en runtime).
4. **Golden rule preservada en cada instante:** Windows nunca apunta a un puerto sin nadie escuchando;
   el registro se cambia a B **después** de que B escucha, y a A **después** de que A escucha.
5. **Degrade garantizado:** si el pool está agotado (rarísimo), se degrada al kill-and-rebind del mismo
   puerto (la ruta de 0006). El modelo relajado es **best-effort para cerrar el hueco**, nunca un
   requisito para la seguridad.

## Consecuencias

**Positivas**
- Filtro **continuo** (cero hueco) durante updates.
- Sin carrera del health check: se cambia solo cuando el nuevo ya escucha.
- El health-check paciente de 0006 deja de ser necesario en el happy path (se mantiene para el degrade).

**Costos / lo que asumimos**
- `proxy-port.txt` pasa a ser **mutable en runtime** durante el cutover; los ~5 consumidores deben
  coincidir en el puerto en el instante del cambio (incl. el `writeChosenPort`-al-escuchar de
  `proxy-server.js:495`, que el proxy-en-B NO debe disparar antes del cutover).
- **Doble cutover** A→B→A por update (más pasos a coordinar).
- Hay que **verificar en HW**: el firewall de un puerto nuevo (casi seguro OK: tráfico loopback exento,
  permiso por-programa `node.exe`) y **medir** la latencia del segundo arranque.

**Reversibilidad**
- Si en HW el cutover resulta frágil, se degrada permanentemente al modelo mismo-puerto de 0006 **sin
  perder seguridad** (la golden rule fail-open se sostiene igual). La decisión no es irreversible.

## Actualización tras el green-loop (2026-07-25) — mecanismo convergido + micro-ventana aceptada

El green-loop (crítico adversario separado, 2 rondas) refinó el mecanismo. Se registra aquí sin alterar la
decisión de arriba; son las consecuencias exactas de implementarla.

- **Fuente de verdad del puerto vivo = el registro `ProxyServer`, no `proxy-port.txt`.** El boceto original
  hablaba de `proxy-port.txt` mutable en runtime; el diseño convergió a algo más simple y seguro: durante
  el cutover `proxy-port.txt` **se queda = hogar**, self-update escribe el **registro**
  (`ProxyServer=127.0.0.1:<puerto vivo>`, siempre DESPUÉS de que ese puerto escuche), y el watchdog, con el
  flag arriba, cede el ciclo de vida pero aplica el golden-rule **reactivamente contra el puerto del
  registro**: vivo → no toca; muerto → internet normal (fail-open). El registro es atómico y sobrevive al
  reboot, así que no hay archivo extra que mantener en sincronía. Única excepción: el degrade
  "home-rebind diferido" (rarísimo) adopta el andamio como hogar escribiendo `proxy-port.txt` — prioriza
  AC1 "nunca sin filtro" sobre AC2 "sin drift", y se re-homea en el próximo update.
- **Kill selectivo por dueño-del-puerto, no `StopWatcherProcesses`.** El proxy se lanza vía VBS detached
  (self-update no ve el PID del node), así que self-update **spawnnea directo** (`process.execPath`,
  `detached+unref`) y mata por **dueño del puerto** filtrado a nuestro `proxy-server.js` — nunca colateral
  al andamio ni a un proceso ajeno.
- **Capas gateadas = las 4 que spawnnean/escriben-registro.** El crítico verificó que WatchdogLoop,
  CheckAndStartProxy, SetProxyByAvailability y **StartProxyAtLogon.bat** (a la que se le agregó el gate vía
  `IsUpdating.ps1`, stale-guarded 15 min) cubren el 100% de los disparadores. SupervisorService solo
  re-arma la tarea del watchdog (no toca proxy ni registro) → no necesita gate.
- **R1 — micro-ventana fail-CLOSED aceptada (irreducible).** En el instante feliz del cutover el registro
  tiene `PE=1→andamio`. Un **corte de luz / reboot exactamente ahí** deja, al volver, Windows apuntando a un
  puerto muerto por **~1 tick del watchdog (5–15s)** hasta que la regla reactiva fuerza internet normal. Es
  **irreducible para cualquier diseño zero-gap** (no se puede hacer el write del registro atómico con un
  apagón físico) y es la contracara de cerrar el hueco fail-OPEN garantizado de ~60–90s de 0006. Se acepta.
  Mitigación incluida: el watchdog corre su chequeo **antes** del `Start-Sleep` (corrección casi inmediata
  al reiniciar), y los crash-handlers de self-update hacen flip-to-normal best-effort en una muerte
  no-apagón. **Aprobado por Felix 2026-07-25.**
- **R5 — `recent-visits.json` / `first-visit.json` protegidos.** La copia temprana del árbol (con el proxy
  viejo aún leyéndolos/escribiéndolos) los sumó a `PROTECTED_RELATIVE_PATHS` en self-update.js, para que un
  update nunca los pise a media escritura.
