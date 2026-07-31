# 0013 — La señal de impresión real (y el detector de reimpresiones)

**Estado: DEFINIDO, sin aprobar. No se construye nada hasta que Felix cierre el candado.**

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
| **`docs/plans/0006`** | Declarado activo en `CLAUDE.md` para v1.0.29, pero `VERSION` ya va por 1.0.34 — **deriva de documentación**: el `CLAUDE.md` debería actualizarse, no este plan. |

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

## Lo que este plan hace posible después (no incluido)

Con el evento 307 fluyendo, el hub podría —en planes aparte— avisar de impresiones fuera del horario
del puesto, de ráfagas anómalas, y de copias a impresoras que no son la de tickets. **Nada de eso
está en el alcance de este plan**, que solo consigue que la señal exista y llegue.
