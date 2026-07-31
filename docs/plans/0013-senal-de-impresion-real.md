# 0013 — La señal de impresión real (y el detector de reimpresiones)

**Estado: APROBADO (2026-07-31) y en construcción.** La señal quedó **observada** en la PC de
pruebas antes de escribir código — ver «OBSERVADO» más abajo.

## Problema (una frase)

El hub declara «trabajo probado» exigiendo tráfico a `qpay.tv`/`opay.tv`, ese tráfico **no
existe** cuando se imprime un ticket, y por tanto **ninguna banca puede aparecer trabajando**, venda
lo que venda.

### Cómo se probó (2026-07-31, no es una sospecha)

Felix imprimió varios tickets reales en una banca real de konfyanslotto/nationlk. Se recompactó esa
ventana a mano y el hub siguió diciendo **«Trabajando 0 min · sin impresión»**. `qpay`/`opay` no
aparecen en `recent-visits.json`, ni en el historial de páginas del hub, **ni en
`blocked-requests.log`** — o sea que no es que el filtro los corte: nadie los llama. Lo único que se
movió fue `api.lotocompany.com` y `konfyanslotto.com`, y ninguno prueba que hubiera una persona,
porque una pestaña abandonada produce los dos.

La señal venía de un comentario en `whitelist.txt` («players que konfyanslotto incrusta al
imprimir»), **nunca observada en un log**. Era una hipótesis, no una señal.

### El segundo problema, del mismo origen

El banquero puede imprimir un ticket a **otra impresora** —hay 5 objetos: dos `EPSON TM-T20II`
extra, `Microsoft Print to PDF` y una `Brother`— y quedarse la copia. Hoy eso es invisible. El
fraude que persigue Nelson es reclamar ganadores no reclamados justo antes de que venza el plazo.

### La señal que sí existe

Windows registra cada documento impreso como **evento 307 de
`Microsoft-Windows-PrintService/Operational`** (impresora, documento, páginas, usuario, hora). En la
PC de pruebas ese log existe pero está **deshabilitado** (`IsEnabled: False`, el default de Windows),
por eso está vacío. Se habilita con `wevtutil sl Microsoft-Windows-PrintService/Operational /e:true`,
que necesita elevación — y el poll ya corre como SYSTEM `/rl highest`.

### OBSERVADO en la PC de pruebas (2026-07-31, `MagaranPrueba`)

Ya no es «la señal que debería existir»: se habilitó el log, se imprimió en la EPSON real y se
miraron los eventos. **Esto es la verdad de campo; nada de lo de abajo es una suposición.**

Un trabajo de impresión produce **5 eventos** (800 spooling → 801 printing → 842 print processor →
805 rendering → **307 documento impreso**). El 307 es el único que significa «salió papel».

Sus campos vienen **estructurados** en `UserData/DocumentPrinted`, no solo en el texto del mensaje
—que está localizado y no se debe parsear—:

| Campo | Valor observado | Uso |
|---|---|---|
| `Param1` | `12` | id del trabajo |
| `Param2` | `Print Document` | nombre del documento — **NO viaja** (fork A) |
| `Param3` | `fcmag` | usuario |
| `Param4` | `\\MAGARANPRUEBA` | máquina |
| `Param5` | `EPSON TM-T20II Receipt` | **impresora** → criterio 5 |
| `Param6` | `ESDPRT001` | puerto |
| `Param7` | `1135` | tamaño en bytes |
| `Param8` | `0` | páginas |

**`Pages printed: 0` en la térmica.** La TM-T20II reporta CERO páginas en un ticket que sí salió en
papel. Contar páginas daría 0 siempre y reproduciría el bug que este plan arregla: **la unidad es el
EVENTO (un 307 = una impresión), nunca `Param8`.** `Param7` (bytes) sí es distinto de cero y sirve
como indicio de tamaño, no como conteo.

**El cursor: `EventRecordID`, monótono y más resistente de lo esperado.**
- Apagar el log (`/e:false`) y volver a encenderlo **no lo borra ni resetea el contador** — los
  registros siguieron 6, 7, 8… con los 5 anteriores intactos.
- `wevtutil cl` (limpiar) tampoco reseteó el contador en esta build: siguió en 11. Aun así, el
  cursor debe **re-anclarse defensivamente** si el máximo del log queda por DEBAJO del guardado
  (otra build de Windows podría resetear) — si no, se saltaría todo en silencio.
- Un `clear` **deja huella**: `System` evento **104**, «The Microsoft-Windows-PrintService/Operational
  log file was cleared». Vector de manipulación distinto al de apagar el log; se anota como observado,
  no se mete en el alcance sin decidirlo.
- Un canal **apagado** sigue reportando su conteo (`numberOfLogRecords: 5`) y su **punta sigue
  consultable** (15). Es decir: en esta build `gli` y la consulta NO se contradicen ahí. Aun así el
  ancla se toma de la punta observada y nunca de un conteo — `gli` ya se pilló mintiendo en
  `oldestRecordNumber`, y una contradicción entre dos sondas debe resolverse hacia sub-contar, que
  cuesta unas impresiones, y no hacia volcar, que pinta la flota de verde.

**Capacidad:** el log es `Circular`, máximo 1 052 672 bytes. A 5 eventos por trabajo, la ventana
ciega de ~55 min queda muy por debajo del punto de vuelta; el riesgo de perder eventos entre pasadas
es despreciable.

**Husos:** el XML trae `TimeCreated` en **UTC** (`2026-07-31T20:22:08Z`) y la PC lo muestra a las
4:22 PM → UTC−4, coherente con `OPERATIONAL_TZ = America/New_York`.

El log quedó **habilitado** en la PC de pruebas por esta verificación, con 15 registros y 3 tickets
de prueba impresos en papel.

---

## Criterios de aceptación

Cada uno comprobable por separado, en la PC de pruebas por SSH salvo donde se diga.

1. **El log queda habilitado y se re-asegura.** Tras una pasada del poll en una máquina con el log
   apagado, `Get-WinEvent -ListLog` lo reporta `IsEnabled: True`. Apagarlo a mano y esperar una
   pasada lo vuelve a dejar en `True`. **No depende de reinicio ni de logon** (convención: la banca
   está días encendida).
2. **Una impresión real produce señal.** Imprimir un ticket y esperar una pasada del poll ⇒ el hub
   recibe un conteo ≥ 1 y una marca temporal, y la pantalla del puesto pasa de «sin impresión» a
   verde en ese tramo.
3. **Cero impresiones ⇒ cero señal.** Una hora con la plataforma abierta y sin imprimir ⇒ el conteo
   es 0 y el tramo NO se pinta verde. (Este es el criterio que impide «arreglarlo» aflojando la
   regla.)
4. **No se cuenta dos veces ni se pierde nada.** El cursor avanza por evento; dos pasadas seguidas
   sin imprimir no reportan nada; una pasada que falla a mitad no salta eventos en la siguiente.
5. **Se distingue la impresora.** El hub puede responder «cuántas impresiones fueron a la impresora
   de tickets y cuántas a cualquier otra», y una impresión a `Microsoft Print to PDF` aparece como
   tal.
6. **El estreno no acusa a nadie.** Una máquina que recibe esta versión por OTA con el log apagado
   **no** genera un evento de manipulación por ese hecho. Solo lo genera si el log se apaga
   **después** de que esta máquina lo haya habilitado al menos una vez (marcador por-máquina, igual
   que `hibernate-baselined.flag` del plan 0012). Ver `wiki/lessons/new-rule-in-a-deployed-detector-self-accuses`.
7. **El hub no se queda a medias.** Si el agente envía la señal nueva y el hub aún no la entiende,
   la pantalla no empeora respecto a hoy; y si el agente es viejo y no la envía, el hub no inventa
   impresiones.
8. **Verificación observable, no autorreferente.** Al menos un criterio se mide **contando tickets
   de papel** salidos de la impresora y comparándolos con el número del dashboard — no leyendo el
   mismo valor que el agente escribió. Ver `wiki/lessons/verification-that-only-checks-what-it-wrote`.

---

## No-objetivos (la valla anti-deriva)

- **NO** aflojar la regla de «trabajo probado» ni volver a contar tráfico de plataforma como
  trabajo. Eso es exactamente lo que hacía que un día en que nadie tocó la PC pesara 4 h 02.
- **NO** leer, guardar ni transmitir el **contenido** de lo impreso, ni el **nombre** del documento
  (cerrado en A).
- **NO** bloquear ni impedir impresiones. Este plan **observa**; el único vector que ya se
  *impide* (`KeepPrintedJobs`) sigue como está.
- **NO** tocar `self-update.js`, `proxy-server.js`, los watchdog `.ps1` ni `BackToNormal.bat` — nada
  aquí roza la regla de oro de fallar abierto.
- **NO** juzgar el reclamo de tickets. El hub ve conducta (impresiones, horas, impresora), nunca el
  estado de un ticket en la plataforma. Detectar «reclamó un ganador no reclamado» **no es posible
  desde aquí** y no se va a fingir que sí.
- **NO** recompactar historia. Los días ya guardados se quedan sin impresiones; el verde empieza a
  existir hacia delante.

---

## Mecánica: dónde vive y con qué cadencia (cerrado)

**Al instalar:** en la pasada de baseline, con el resto del hardening.

**Después:** lo re-asegura el **poll**, no el arranque ni el login. `reassertHardeningIfDue()` en
`poll-hub.js` ya lanza `HardenPrinters.ps1` y `HardenPower.ps1` como SYSTEM cada **~55 min**
(`HARDEN_MAX_AGE_MS`); la comprobación del log entra **dentro de `HardenPrinters.ps1`** — mismo
dominio (impresoras), misma elevación, misma cadencia, mismo contrato de código de salida.

**Por qué no puede ser solo al instalar:**
- Las máquinas ya instaladas reciben esto por OTA y **nunca se reinstalan**.
- Una banca se queda encendida DÍAS, a veces solo bloqueada. Una tarea `onlogon` no dispara al
  despertar de hibernación ni al desbloquear, así que «se re-asegura en cada login» puede ser «no se
  re-asegura en una semana». Esto ya mordió a los dos scripts de hardening — ver `docs/plans/0010`.
- El poll SYSTEM `/rl highest` es el **único** gancho elevado siempre activo: los watchdog de
  frecuencia por minuto corren como `BUILTIN\Users` y no pueden tocar configuración de máquina.

**Hereda el contrato de código de salida (plan 0011):** si habilitar el log no se puede *verificar*,
el guard no devuelve 0, y entonces `guards-ok.txt` no se sella y `guards_checked_at` no avanza. Un
guard no evaluado no es un guard limpio.

**La ventana ciega, dicha en claro:** entre pasadas hay hasta ~55 min. Alguien que conozca el truco
podría apagar el log, imprimir y volver a encenderlo, y esas impresiones no se verían. **Pero el
apagado sí deja marca**: la siguiente pasada lo detecta y —con el trato de baseline del criterio 6—
lo reporta como manipulación. O sea que el fraude pierde las impresiones pero no la huella. Reducir
esa ventana es un cambio de cadencia, no de diseño, y no se hace sin medir lo que cuesta.

---

## Contratos y zonas bajo ADR que se rozan

| Contrato | Cómo se roza |
|---|---|
| **Regla de oro (fallar ABIERTO)** | No se toca. Nada de este plan está en el camino del proxy o del internet. |
| **Contrato de poll entre repos** | **SE AMPLÍA**, aditivo: un campo nuevo en el body. El hub debe aceptarlo y seguir funcionando con agentes viejos que no lo manden (criterio 7). Hay que comentar «cross-repo contract» en los dos lados. |
| **ADR 0001 / 0002** | No se tocan (puerto en cutover; whitelist que falla abierto). |
| **Repo PÚBLICO** | Ningún dato de máquina ni de ticket entra al repo. Cerró el fork A: el nombre del documento no viaja. |
| **`docs/plans/0006`** | Era **deriva de documentación** y quedó CERRADA en este mismo cambio: se envió como v1.0.29, su AC4 diferido lo cubrió `0008`, y `0007` superó todo el camino de actualización. El `CLAUDE.md` ya no lo declara activo. |

---

## Marcha recomendada: **FULL-ORCHESTRATOR**

Con reviewer separado y prueba en la PC física como puerta E2E. Motivos, y basta con uno:

1. **Son dos repos** (agente + hub) con un contrato entre ellos.
2. **Toca un detector ya desplegado** (`HardenPrinters.ps1` y sus tampers), donde una regla nueva
   se auto-acusa el día del estreno si no se trata con cuidado.
3. **Superficie sensible de datos**: lo que se imprime en una banca son tickets de clientes.
4. **Cambia lo que Nelson considera «trabajo»**, que es la base sobre la que juzga a su gente. Un
   falso verde y un falso ámbar cuestan los dos, en direcciones opuestas.

---

## Preguntas cerradas (2026-07-31) — ya no bloquean

**A. El nombre del documento NO se manda.** Impresora + conteo + hora resuelven las dos conductas
que importan: el verde, y la copia a otra impresora. El nombre puede llevar número de ticket o datos
del cliente y quedaría guardado en la base del hub, a cambio de un poder de detección que hoy no
necesitamos. Si alguna vez hace falta correlacionar reimpresiones del MISMO documento, se manda un
**hash** del nombre — misma correlación, sin el texto.

**B. Qué impresora es «legítima» NO se decide ahora: se registra.** Se guarda a qué impresora fue
cada trabajo y no se declara ninguna política. Escribir hoy «imprimir a PDF es sospechoso» sería
cementar una suposición con **cero observaciones**, que es exactamente el error que produjo este
plan: `qpay.tv` era una regla escrita desde un comentario, sin haber mirado un log jamás. Se mira
una semana de bancas reales y entonces se decide. **Cuando se decida, que sea señal y no veredicto**
— una alerta dura equivocada quema la confianza en todas las demás.

**C. El plazo de reclamo queda FUERA de alcance.** Solo hace falta para detectar «ráfaga cerca del
vencimiento», que es un plan de alertas posterior. Este plan solo consigue que la señal exista y
llegue; sin ese número, esa detección no se construye y no se finge que existe.

**Consecuencia: no queda ninguna pregunta abierta.** El plan está listo para construirse en cuanto
Felix apruebe el candado.

## Diseño cerrado (2026-07-31, tras dos rondas de crítico separado)

Verificado por SSH además de lo de arriba: `wevtutil qe <canal> /q:"*[System[(EventID=307) and
(EventRecordID>N)]]" /f:xml /c:N /rd:false` funciona (exit 0, XML limpio, **`/rd:false` = el más
VIEJO primero**), mientras que `Get-WinEvent -FilterHashtable` **no acepta `EventRecordID`**.
`wevtutil gl` da `enabled:`; `wevtutil gli` da `numberOfLogRecords:`. Un canal inexistente sale
15007 en ambos.

**La trampa que obliga a todo lo demás:** un **XPath inválido sale con código 0 y salida VACÍA** —
una consulta rota es indistinguible de un día sin ventas. Y `gli` reportó `oldestRecordNumber: 1`
cuando los registros reales iban del 11 al 15 (tras un `clear`): **ese campo no sirve para derivar
el cursor**; la punta se saca consultando el evento más nuevo.

### Agente

1. **El guard solo habilita.** Dentro de `HardenPrinters.ps1`, el bloque del log va **ARRIBA del
   gate de PrintManagement** (el `spawnSync` del poll tiene un presupuesto de 25 s compartido y
   `Get-Printer` puede colgarse contra una impresora de red muerta). Diff mínimo: el bucle de
   Keep=OFF no se toca ni una línea, el gate solo gana una salida con precedencia **2 > 3 > 0**
   escrita. Verificación **releyendo el estado**, nunca dando por bueno el `sl` que acaba de
   escribir — y esa relectura va por `wevtutil gl`, no por `Get-WinEvent -ListLog`: cargar el módulo
   Diagnostics delante del bucle Keep=OFF metía un cuelgue posible en el presupuesto de 25 s del
   guard anti-reimpresión. (El exit de `wevtutil` sí decide *ilegible*; nunca decide *apagado*.)
   Marcador
   `print-log-baselined.flag` como `hibernate-baselined.flag` de 0012. **Ilegible ≠ apagado**: con
   `$ErrorActionPreference='SilentlyContinue'`, `$null.IsEnabled` se lee como «apagado» y fabricaría
   una MANIPULADA roja falsa — ilegible va al carril de fallo, jamás al de acusación (precedente
   `HardenPower.ps1:142-144`).
2. **El cosechador es dueño ÚNICO del cursor.** Vive en `poll-hub.js` y corre en cada poll (~2 min)
   con `wevtutil`, sin PowerShell. Si el ancla la escribiera el guard (55 min) y la leyera el
   cosechador (2 min), habría ~27 pasadas con el cursor ausente y el volcado del log entero seguiría
   alcanzable. Cursor ausente ⇒ anclar a la punta y postear **cero** eventos. Cursor ilegible ⇒
   **ausente**, nunca `0`: el idioma reflejo `parseInt(raw) || 0` **es** el volcado. El ancla sale
   **siempre de la punta observada, jamás de un conteo** — `numberOfLogRecords` de `gli` sirve solo
   para lo otro: si es `> 0` y la consulta de punta no devuelve nada, la **consulta está rota** ⇒ no
   anclar, no cosechar, registrar el fallo. `/rd:false` + tope ⇒ se llevan los N **más viejos** por
   encima del cursor (con `-MaxEvents` se llevaría los nuevos y los viejos desaparecerían en
   silencio). Se manda `record` (`EventRecordID`) como identidad estable. **El cursor avanza tras un
   post 2xx** en el camino normal; hay dos avances SIN post, deliberados y acotados: el ancla del
   estreno (no hay nada que postear) y el salto sobre eventos ilegibles (garantía de progreso).
   `print-cursor.txt` entra en `PROTECTED_RELATIVE_PATHS` de `self-update.js` y en `.gitignore` —
   si viajara en el bundle heredaría `+h +s` y `writeFileSync` daría EPERM, congelando la cosecha
   sin que se entere nadie.
3. **El fallo del XPath es de VERSIÓN, no de máquina**, así que se caza donde ya hay dientes: una
   7ª invariante en `self-test.js` («la plantilla del 307 devuelve ≥1 evento contra un log con ≥1
   307»), que viaja en `body.selftest` y cuyo `fail` **detiene el rollout** en el anillo de staging.
   El objeto de salud `print_log {enabled, tip, cursor}` **acompaña, no sustituye** — y su sonda
   sale de `gl`/`gli`, comandos con un modo de fallo distinto al de la plantilla de cosecha, o se
   certificaría a sí mismo.

### Hub

4. Migración **0025** (libre verificado en todas las ramas): `machine_print` con
   `record_id`, dedup `(machine_id, at, record_id)` — con `(machine_id, at, printer)` dos documentos
   al mismo segundo se descartarían en silencio. `received_at` separado de `at`. Retención **60
   días**, por encima de la recompactación de 72 h: si se podara por debajo, esa recompactación
   **borraría el verde** de los últimos 3 días al reconstruir intervalos sin los prints.
5. `poll/route.ts` acota `last_print_at` con **`now - STALE_AFTER_MS`** (6 min, ya importado ahí).
   No «el sample previo»: esa ruta tiene prohibido leer (~216k llamadas/día). Y no `last_seen_at`,
   porque compararía reloj del agente contra reloj del hub — una banca con el reloj **atrasado**
   más que el intervalo de poll quedaría ciega para siempre. Cualquier evento más viejo que 6 min
   cae en un hueco que `buildIntervals` ya clasifica `offline` sin mirar los prints, así que la cota
   no pierde nada que pudiera pintar verde.
6. qpay/opay **se mueven al lane `platform`**, no se borran: fuera de `WORK_LANES` pasarían a
   navegación personal (morada). La whitelist no se toca.
7. **El puente (decidido por Felix):** un tramo `work` continuo con ventas probadas en ambos
   extremos cuenta entero como trabajo probado. No es un umbral de minutos inventado — el puente se
   corta en cuanto hay `idle`/apagada/navegación. Sin esto, 40 tickets en 10 h leen «Trabajando
   1 h 20». El predicado vive en UN sitio para que la barra y los minutos no se contradigan.
8. **Severidad `print-log` = ROJA (decidido por Felix).** Apagar ese log no tiene causa accidental.
   Ojo al registrar el slug: `HardenPrinters.ps1` tiene **tres** llamadores —el poll, el instalador
   y `CleanPrintSpoolOncePerDay.bat` en cada logon— así que dos invocaciones cercanas con el log
   apagado pueden escribir dos tampers con `at` distinto que el índice de dedup no colapsa. El
   umbral rojo debe leerse como «cualquier revert de `print-log` es rojo», no «dos incidentes».
9. Los criterios 5 y 8 necesitan **una pantalla** que lea `machine_print`: `print_windows` es un
   piso documentado («varias impresiones en el mismo tramo de ~2 min cuentan como una»), así que
   contar tickets de papel contra ese número fallaría por diseño.

## ORDEN DE DESPLIEGUE — el hub PRIMERO. No es una preferencia.

**El hub va antes que el OTA del agente, siempre.** Si sale primero el agente v1.0.35 contra el hub
actual, ocurre esto: el hub no conoce `print_jobs`, lo descarta en silencio (su parseo no valida
esquema) y **responde 200**. `postJson` solo rechaza fuera de 2xx, así que el agente lo toma por
entregado, **avanza el cursor**, y esas impresiones no se vuelven a mandar jamás. El criterio 4
(«no se pierde nada») se rompe sin un solo error en ninguna parte — no por el código, por el orden.

Secuencia correcta:
1. `supabase db push --linked` (migración 0025: `machine_print`, las 3 columnas de salud en
   `machines`, y el umbral `print-log` en `alert_settings`).
2. `vercel --prod --yes` desde `watcher-fleet`.
3. Recién entonces: bundle + copia del zip + `node --env-file=.env.local scripts/publish-agent.mjs`.

El paso 1 antes del 2 también importa: el hub nuevo escribe columnas que la migración crea.

## Guion de QA — tres relojes distintos, no uno

Lo que sigue evita perseguir fallos falsos. Cada criterio depende de una cadencia diferente:

- **Criterio 1 (log habilitado)** depende del *throttle del guard*, no del poll: `harden-last.txt`
  sobrevive al OTA, así que pueden pasar hasta **55 min** antes de la primera re-aserción. Para
  probarlo ya: borrar `harden-last.txt` y esperar un poll. La frase «tras una pasada del poll» del
  criterio se lee como «tras una pasada de re-aserción».
- **Criterio 2 (verde en pantalla)** depende además de la *compactación*, que no está en
  `vercel.json`: vive en `.github/workflows/audit-compact-cron.yml` (`7 * * * *`, best-effort, puede
  atrasar 10-30 min). Pártelo en dos: primero comprobar que la fila llega a `machine_print` y que
  `last_print_at` avanza; luego disparar el `workflow_dispatch` a mano y mirar la barra.
- **Criterio 3 (cero impresiones ⇒ cero señal)** solo vale medido en la **misma sesión** en que el
  criterio 2 salió verde en esa máquina. Si no, una cosecha rota lo satisface igual de bien que un
  día tranquilo — que es el fallo que este plan existe para no repetir.
- **Criterio 8** se mide contando **papel**, contra el panel de Impresión del puesto (que lee
  `machine_print` fila a fila), **no** contra el chip de «N impresiones» de auditoría: ese cuenta
  ventanas de ~2 min y es un piso declarado, así que discreparía por diseño.

**El estreno se verá atascado y es normal.** Tras el OTA, hasta que el guard habilite el canal, la
7ª invariante devuelve `skip` ⇒ el hub clasifica `incomplete` ⇒ `hold("staging-selftest-incomplete")`
y la suite se reintenta cada 30 min. Cuenta con ~85 min hasta que abra el anillo 0. **Ojo: la PC de
pruebas NO va a ejercitar ese camino**, porque su canal quedó habilitado a mano durante la
observación del 31/07 — la primera vez que se verá de verdad es en una banca real.

## Residuos conocidos (aceptados, no olvidados)

- **Ventana ciega de ~55 min** para el encendido: quien conozca el truco puede apagar el log,
  imprimir y encenderlo. Pierde las impresiones, no la huella — la siguiente pasada lo reporta.
- **`print-log` es ROJO al primer revert.** Sin verificar: el servicio de eventos de Windows *puede*
  deshabilitar un canal cuyo `.evtx` esté corrupto. Si eso pasa, se reporta como manipulación roja
  sin serlo. Merece una comprobación antes de que haya bancas reales en rojo — una alerta dura
  equivocada quema la confianza en todas las demás, que es el argumento de la pregunta cerrada B.
- **Impresiones fuera de un tramo con sondeo** (la máquina no estaba polleando) aterrizan en
  `machine_print` pero NO pueden pintar la barra: caerían en un tramo `offline`, y pintarlo verde
  sería mentir. La evidencia se conserva; el gráfico no la usa.
- **El salto sobre eventos ilegibles cambia «atasco» por «pérdida», a propósito.** Si el parseo se
  rompiera, antes el cursor se congelaba —ciego, pero los eventos seguían en el log— y ahora se
  salta hasta 50 por pasada, que no vuelven. Se acepta porque el canal es circular de ~1 MB: una
  banca activa da la vuelta en menos de un día, así que lo que el salto tira lo habría tirado el
  wrap igual, y a cambio el flujo no se muere para siempre. La 7ª invariante es lo que impide que
  ese escenario llegue a una banca.

## Lo que este plan hace posible después (no incluido)

Con el evento 307 fluyendo, el hub podría —en planes aparte— avisar de impresiones fuera del horario
del puesto, de ráfagas anómalas, y de copias a impresoras que no son la de tickets. **Nada de eso
está en el alcance de este plan**, que solo consigue que la señal exista y llegue.
