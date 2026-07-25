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
