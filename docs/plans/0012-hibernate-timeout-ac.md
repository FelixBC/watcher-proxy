# 0012 — La banca enchufada tampoco debe hibernar (`hibernate-timeout-ac`)

**Status:** CONSTRUIDO + verificado en HW (2026-07-31). Aprobado por Felix el mismo día.
Pendiente: cross-review de Codex, y el gate largo AC10 (>3 h enchufado sin hueco de señal).
Gear:
**SINGLE-CONCERN** (un área — el hardening de energía del agente; sin superficie de
dinero/auth/tenancy/ADR, no toca el filtrado ni la regla de oro), con **reviewer
separado + verificación en HW real** como gate antes de publicar, igual que sus dos
hermanos 0009 y 0010.

Ships as **v1.0.34** por el pipeline normal de release + OTA. El gate de staging
(plan 0003) lo valida antes de abrir a cualquier banca.

## Problema (una frase)

`HardenPower.ps1` fuerza `standby-timeout-ac 0` pero **nunca toca
`hibernate-timeout-ac`**, que sigue en su default de Windows (3 h), así que una banca
**enchufada e inactiva 3 h se hiberna sola y desaparece del fleet** — exactamente el
fallo que el plan 0009 quería cerrar, entrando por otra puerta.

## Background (medido en HW, no inferido)

En el test PC el 2026-07-31, tras 13 h sin reportar al hub:

```
POWER_ONLINE   = True                      (portátil, ENCHUFADO)
Sleep after     (STANDBYIDLE)  AC=0  DC=0   ← el fix del 0009 aplicó y aguanta
Hibernate after (HIBERNATEIDLE) AC=DC=0x2a30 = 10800 s = 3 h   ← el 0009 nunca lo tocó
```

Eventos de energía de la máquina:

```
Wake Source: S4 Doze to Hibernate
Sleep Time:  2026-07-31T02:13:37Z   → 30/07 22:13 local
Wake Time:   2026-07-31T13:03:36Z   → 31/07 09:03 local
```

Última actividad ~19:12 → hibernación 22:13: **exactamente los 10800 s**. El
`LastBootUpTime` seguía marcando 24 h de uptime (hibernar no reinicia el contador),
que es justo lo que hace que este fallo se lea como "apagada" o "robada".

**Por qué `standby-timeout-ac 0` no lo evitó:** en máquinas con *Modern Standby* (S0)
el "Sleep after" clásico queda inerte, y quien gobierna la caída a S4 es
`HIBERNATEIDLE` — el "Doze to Hibernate". Poner el standby en 0 fue correcto y sigue
siendo necesario; simplemente no es el knob que gobierna esta transición. Son
**dos ajustes distintos** y el 0009 solo escribió uno.

**Por qué el 0009 no lo cazó:** su AC6 verificaba en HW "el índice Wi-Fi AC+DC = 0 y
`standby-timeout-ac` = 0" — es decir, comprobaba **exactamente lo que ese plan
escribía**. Una verificación así no puede, por construcción, descubrir el knob que
faltaba.

## Impacto (por qué se arregla ahora y no en el backlog)

1. **Producto:** `CLAUDE.md` fija que una banca se deja encendida DÍAS. Hoy Windows la
   apaga cada 3 h de inactividad. Es el supuesto central del diseño, roto.
2. **Anti-robo:** el silencio nocturno es el falso positivo más caro que existe en este
   producto. Yo mismo, con acceso completo al repo y al dashboard, abrí la sesión del
   31/07 leyendo "13 h sin señal" como máquina apagada o robada. Si a Nelson le pasa
   cada noche, aprende a ignorar la única señal que debe mirar.
3. **Rollout:** en la máquina de staging congela cualquier gate en silencio
   (`staging-not-ready`, `cron/rollout/route.ts:371`). Con `STAGING_TIMEOUT_MS` = 24 h,
   un release publicado de tarde puede llegar a `staging-timeout` antes de que la caja
   despierte. Pasó: el despliegue de v1.0.33 estuvo ~19 h de 24 detenido por esto.

## Decisiones cerradas (Felix, "haz lo que recomiendas", 2026-07-31)

- **A — Alcance: SOLO AC.** `hibernate-timeout-ac 0`; el comportamiento en batería
  (DC) queda **intacto**, coherente con la decisión A del plan 0009 (el sueño en
  batería se dejó a propósito: no acelerar una batería que se muere). Una banca
  desenchufada 3 h es, además, una anomalía que sí queremos ver.
- **B — Vehículo de re-aserción: ninguno nuevo.** El ajuste entra dentro de
  `HardenPower.ps1`, así que **hereda gratis** los tres invocadores que ya existen:
  install (`InstallWatcher.bat -Baseline`), la tarea de logon
  (`CleanPrintSpoolOncePerDay.bat`) y — la que de verdad cuenta — el re-assert ~55 min
  de `poll-hub.js reassertHardeningIfDue()` desde la tarea SYSTEM `WinConfig Sync`
  (plan 0010). Cero wiring nuevo, cero tareas nuevas.
- **C — La primera aplicación NO es un tamper.** Ver §El trampa abajo: se resuelve con
  un marcador de baseline por-máquina, no relajando la señal de tamper.

## La trampa que este plan DEBE evitar (falso `tamper` en toda la flota)

`HardenPower.ps1` clasifica una escritura en tres cubos: `$changed` (valor previo
**legible y no-cero** → es un revert confirmado → emite `tamper | setting=power`),
`$corrected` (previo desconocido → informativo) y `$failed` (no aplicó → exit 2).

En una banca cuyo `HIBERNATEIDLE` esté **escrito explícitamente en el registro**
(imagen OEM, o un admin que tocó las opciones de energía), la primera corrida del bloque
nuevo lo verá legible y no-cero, lo forzará a 0 y lo clasificará como **revert
confirmado** → `tamper`. Y `poll-hub.js` invoca el script **sin `-Baseline`** (solo
`InstallWatcher.bat` lo pasa), así que al aterrizar la v1.0.34 por OTA esas máquinas
levantarían una bandera roja "MANIPULADA" — el mismo falso positivo que este plan existe
para eliminar.

**Matiz medido en HW (2026-07-31), que acota el alcance de la trampa:** en el test PC el
subgrupo Sleep del esquema activo tiene **un solo hijo**, `29f6c1db` (STANDBYIDLE, AC=0
— lo escribió el 0009). `HIBERNATEIDLE` **no tiene entrada de registro**: los 3 h que
reporta `powercfg /q` son el **default heredado del esquema**, no un valor persistido. En
esas máquinas `Get-RegIndex` devuelve `$null`, `$hiberReadable` es `$false` y la ruta
`$corrected` que ya existía habría evitado el falso tamper por sí sola. O sea: la trampa
**no** afecta a "toda la flota" como se escribió primero, sino al subconjunto con el valor
persistido. El marcador sigue siendo necesario —ese subconjunto existe y no es
observable desde acá— pero el riesgo estaba sobredimensionado y queda corregido.

**Fix:** un marcador por-máquina `WatcherBrain/hibernate-baselined.flag`. Ausente = este
equipo nunca ha tenido el knob forzado → la aplicación es housekeeping
(`power-hardened`, informativo) y se escribe el marcador. Presente = un valor no-cero
**sí** es un revert genuino → `tamper`. Así se conserva la señal anti-robo (alguien que
re-habilita la hibernación para dejar una máquina a oscuras ES una manipulación) sin
disparar la alarma en el despliegue. Se gitignorea, como todos sus hermanos, y el
comentario debe decir por qué (el excluidor del bundle es `.gitignore`-driven).

Deliberadamente **específico de hibernate y no un mecanismo genérico**: es el segundo
ajuste, no el tercero — generalizar ahora sería especulativo.

## Acceptance criteria

1. `HardenPower.ps1` declara el GUID `HIBERNATEIDLE`
   (`9d7815a6-7ee4-497e-8888-515a05f02364`, subgrupo Sleep `238c9fa8-…` ya presente) y
   fuerza `hibernate-timeout-ac 0` **solo en AC**, con el mismo patrón que el bloque de
   standby: leer el índice del registro, escribir vía `powercfg /change`, y **re-leer el
   registro para verificar** — nunca confiar en la escritura.
2. Tras una corrida en el test PC, `HIBERNATEIDLE` **`ACSettingIndex = 0`** y
   **`DCSettingIndex` sin cambio** respecto de su valor previo (`0x2a30`). Comprobable
   por SSH leyendo el registro.
3. **Idempotencia:** una segunda corrida no cambia nada y **no escribe una sola línea**
   en `events.log`.
4. **Sin falso tamper:** en una máquina que ya tenía `hibernate-baselined.flag` ausente y
   `HIBERNATEIDLE ≠ 0` (el estado de toda banca instalada hoy), la primera corrida
   **sin** `-Baseline` escribe `power-hardened` y **NO** escribe ninguna línea `tamper`.
   Comprobable: borrar el flag, poner el valor a 10800, correr sin `-Baseline`,
   `grep tamper events.log` → sin coincidencias nuevas.
5. **La señal de tamper sobrevive:** con el flag YA presente, poner `HIBERNATEIDLE` a
   10800 y correr → escribe `tamper | setting=power` y el fleet lo recibe en el poll
   siguiente (verificable en el dashboard, dimensión `power`).
6. **Contrato de exit-codes intacto:** 0 = verified-clean, 2 = harden-failed (una
   escritura de hibernate que no toma se une a `$failed`), 3 = skip. `poll-hub.js` no
   cambia: sigue exigiendo un 0 explícito para estampar `guards-ok.txt`.
7. **Regla de oro:** el script sigue sin leer/escribir `ProxyEnable`/`ProxyServer`, sin
   arrancar/parar el proxy y sin tocar routing. Verificable por lectura del diff.
8. `WatcherBrain/hibernate-baselined.flag` está en `.gitignore` con un comentario que
   explica que es estado por-máquina y **nunca** debe viajar en el bundle.
9. `VERSION` 1.0.33 → **1.0.34**.
10. **E2E en HW:** en el test PC, tras aplicar y esperar >3 h de inactividad enchufado,
    la máquina **sigue reportando** al hub (sin gap en `última señal`). Este es el
    criterio que de verdad cierra el problema; los demás son sus condiciones.

## Non-goals (explícito)

- **No** tocar el comportamiento en **batería** (DC) — decisión A. Ni hibernate ni sleep.
- **No** deshabilitar la hibernación del sistema (`powercfg /hibernate off`): eso rompería
  Fast Startup y el archivo de hibernación. Solo se pone el **timeout de inactividad en
  AC** a "nunca".
- **No** un mecanismo genérico de "baseline por ajuste" — el marcador es específico de
  hibernate (§La trampa).
- **No** nuevas tareas programadas ni nuevos invocadores — decisión B.
- **No** tocar `poll-hub.js`, el filtrado, el self-update, ni ningún camino de la regla
  de oro. El único archivo de comportamiento que cambia es `HardenPower.ps1`
  (+ `.gitignore` + `VERSION`).
- **No** re-abrir el aviso mal calibrado del cron de rollout (`*/15` declarado vs. 1–3.5 h
  reales de GitHub Actions) — es real y está anotado, pero es **otro problema**, en el
  otro repo, y va en su propio plan.

## Contracts & ADR-locked areas touched

- **Regla de oro** (`CLAUDE.md`, `ARCHITECTURE.md` §Watchdog): **no tocada**.
  `HardenPower.ps1` es ortogonal al filtrado por diseño y este cambio no altera esa
  propiedad — se limita a añadir un tercer ajuste de energía dentro del mismo script.
- **`docs/adr/0001`** (relax port lock during update cutover) y **`0002`** (filter fails
  open on unusable whitelist): **ninguno tocado**. Este cambio no roza puertos, cutover,
  ni whitelist. **No hay conversación de ADR aquí.**
- **Contrato cross-repo con `watcher-fleet`:** solo se **consume**, no se cambia. El
  script emite el tag `tamper` con `setting=power`, dimensión que la migración 0022 del
  plan 0011 ya entiende. No hay cambio de esquema, de ruta, ni de payload.
- **Convención del bundle** (`.gitignore`-driven): se **consume** añadiendo una entrada,
  que es exactamente el patrón que ya siguen `staging.flag`, `guards-ok.txt` y
  `harden-last.txt`.
- Sin DB, sin secretos, sin auth, sin dinero, sin tenancy.

## Open questions

Ninguna abierta. A/B/C cerradas; el GUID y el default de 3 h están **verificados en
hardware**, no asumidos; el vehículo de re-aserción ya existe y está probado por el plan
0010; la trampa del falso tamper está identificada con fix y con criterio de aceptación
propio (AC4/AC5).

## Verification plan

- **Estático:** parse de PowerShell (`[ScriptBlock]::Create`) de `HardenPower.ps1`;
  confirmar que ninguna ruta nueva puede lanzar (todo envuelto / `SilentlyContinue`) y
  que el script sigue terminando siempre en un exit-code del contrato.
- **Reviewer separado:** subagente Opus + `codex exec` — doctrina del repo para cambios
  adyacentes a la regla de oro y al hardening. Hallazgos aplicados, y **la 2ª pasada va
  sobre los arreglos**, no solo sobre el diff original.
- **HW (el gate real):** por SSH al test PC — AC2 (registro AC=0, DC intacto), AC3
  (2ª corrida muda), AC4 (borrar flag + 10800 + correr sin `-Baseline` → sin `tamper`),
  AC5 (con flag + 10800 → `tamper` visible en el dashboard). Y finalmente AC10: dejarlo
  enchufado e inactivo >3 h y confirmar que **no hay gap** en la última señal.
- Después Felix es dueño de git/release/OTA; el gate de staging valida antes del anillo 0.

## Resultado de la verificación en HW (2026-07-31, test PC, PS 5.1)

Corrido desde un directorio aislado (`Downloads\hp-test`) para no ensuciar el install real.

| criterio | resultado |
|---|---|
| Parse con el parser del runtime destino | `PARSE=OK`, sesión `ELEVATED=True`, PS 5.1.26100 |
| **AC2** registro AC=0, DC intacto | `REG_AC=0`, efectivo `AC=0x00000000` / **`DC=0x00002a30`** |
| **AC3** idempotencia | 2ª corrida: `LINES_BEFORE=1 LINES_AFTER=1`, exit 0 |
| **AC4** primer forzado sin marcador | `power-hardened … no-hibernate-ac`, **`TAMPER_COUNT=0`** |
| **AC4-bis** previo legible ≠0 **sin** marcador | `power-hardened`, **0 tampers** (el caso OEM) |
| **AC5** previo legible ≠0 **con** marcador | `tamper \| setting=power \| … no-hibernate-ac` |
| **AC6** contrato de exit-codes | `EXIT=0` en las 4 corridas verified-clean |
| Estado final de la máquina | `FINAL_EFF_AC=0x00000000`, `FINAL_EFF_DC=0x00002a30` |

**Nota de unidades:** `powercfg /change <alias>` toma **minutos**, no segundos (al fijar
10800 para la prueba el registro guardó `648000` s). Irrelevante para el fix — el valor que
escribimos es `0`, idéntico en ambas unidades — pero anotado para que nadie lea `/change
hibernate-timeout-ac 180` como "3 horas en segundos".

Pendiente de este plan: **AC10**, que es un gate de reloj (>3 h) y no se puede forzar.

## Cross-review de Codex (2026-07-31) — triaje

**P2-1 · Un fallo al escribir el marcador desactivaba en silencio la detección futura, y aun
así devolvía exit 0 → ACEPTADO y arreglado.** Codex tiene razón: mi comentario original
justificaba tragarse el fallo como "solo puede perder señal, nunca fabricarla", pero eso deja
el guard reportando *clean* mientras ha perdido la capacidad de detectar justo lo que existe
para detectar, y `poll-hub.js` estampa `guards-ok.txt` sobre esa mentira. `Set-HiberBaseline`
ahora devuelve un booleano **verificado releyendo** el marcador, y un fallo entra al camino
exit 2 con su propia línea de log. Es la misma doctrina que el resto del script: un deploy roto
tiene que ser VISIBLE, nunca un falso éxito silencioso.

**P2-2 · Dos invocaciones concurrentes pueden reportar un mismo revert 2-3 veces → RECHAZADO
para este plan, anotado como limitación conocida.** La carrera es real, pero **no la introduce
este cambio**: los bloques de Wi-Fi y de standby tienen exactamente la misma forma
(leer → forzar → clasificar → `Write-Event 'tamper'`) desde la v1.0.31, y pasaron dos revisiones.
Serializar con un mutex de máquina significa meter estructura nueva en un script best-effort
cuyo contrato es *no lanzar nunca*, dentro del mismo release que arregla la energía — se amplía
la superficie de riesgo por una distorsión que jamás se ha observado, y encima la ventana es
estrecha (el poll se auto-limita a ~55 min con `harden-last.txt`, y la tarea de logon casi no
dispara en una banca, que es toda la premisa del plan 0010). Si algún día se ve frecuencia
inflada en el ladder del 0011, el arreglo correcto es un mutex **para los tres ajustes a la vez**,
en su propio plan.

**Deriva de comentario → ACEPTADO y arreglado.** El comentario del bloque afirmaba que toda
máquina instalada tiene el valor legible y no-cero, que es justo lo que la medición en HW
desmiente. Corregido en el mismo cambio, con el hallazgo medido escrito al lado para que nadie
lo vuelva a derivar.

Codex despejó explícitamente: semántica `$null`/0 en PS 5.1 correcta, ninguna ruta nueva que
lance, DC nunca escrito, el marcador sobrevive a OTA y a rollback, y la regla de oro intacta.
