# sherman-svelte-runner

Runner self-hosted para la CI de **Sherman-svelte**. Es una imagen **derivada**
de [`gh_runner`](https://github.com/JoseAmador95/gh_runner) (el deployer genérico)
con el toolchain del proyecto y sus servicios sidecar.

**gh_runner sigue siendo genérico**; aquí vive solo lo específico del proyecto:

| Pieza | Qué aporta |
|-------|-----------|
| `Containerfile` | `FROM ghcr.io/joseamador95/gh_runner:latest` + Node 22 (`engines.node ">=22"`) + pnpm vía corepack (el proyecto fija `pnpm@10.29.3`) + Playwright (libs del sistema) + el `ENV` que pone el store de pnpm en `_work` (instala por hard-links). |
| `compose.override.yaml` | Verdaccio (registry npm pull-through) compartido por los runners del host, alcanzable como `http://verdaccio:4873`. |
| `.github/workflows/build-image.yml` | Build multi-arch (amd64+arm64) a `ghcr.io/<owner>/sherman-svelte-runner:latest`, con `schedule` diario para heredar los arreglos del base. |
| `.github/workflows/vigilar-runners.yml` + `scripts/vigilar-runners.mjs` | Vigía horario del fleet: avisa por Telegram cuando un runner se cae o vuelve. Ver [Vigilancia del fleet](#vigilancia-del-fleet). |
| `scripts/configurar-avisos.sh` | Deja listos los avisos del vigía **del host** (gh_runner) en una máquina: escribe su configuración, activa los hooks y **prueba cada canal**. |

> **Nombre del repo / owner.** Hoy el remoto es `JoseAmador95/svelte-runner`; hay que
> **renombrarlo a `sherman-svelte-runner`** (el nombre de la imagen sale de
> `${{ github.repository }}`). Empieza bajo `JoseAmador95` y luego se traspasa a
> **`demeneghi`** (donde ya vive la app `demeneghi/sherman-svelte`). El label
> `org.opencontainers.image.source` lo reescribe el CI automáticamente.

## Desplegar

En una máquina del fleet, en un **directorio dedicado**. Este comando baja el
`compose.override.yaml` de este repo y, si la descarga fue bien, corre el `deploy.sh`
de gh_runner — encadenados con `&&`. `deploy.sh` generará ahí `compose.yaml` y el plugin
de Compose autofusiona el override al hacer `up -d`.

```bash
# NINGÚN secreto va en el comando: te los pregunta al vuelo, así no quedan en el
# historial del shell. Son dos: el PAT (al empezar) y la ping key de
# healthchecks.io (al configurar los avisos).

curl -fsSL -O https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/compose.override.yaml \
  && sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)" -- \
       --repo demeneghi/sherman-svelte \
       --image ghcr.io/joseamador95/sherman-svelte-runner:latest \
       --labels sherman,self-hosted \
       --count 3 --vigilar --no-up \
  && sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/scripts/configurar-avisos.sh)" \
  && podman compose up -d
```

Cuatro tramos encadenados con `&&`: baja el `compose.override.yaml`, **genera** el despliegue
con el vigía puesto (**`--vigilar`**, ver [Vigilancia del fleet](#vigilancia-del-fleet)),
configura por dónde te avisa, y **solo entonces levanta el cluster**.

**El `--no-up` es a propósito.** Los avisos se configuran **antes** de que arranque nada: si la
ping key está mal, el comando se corta ahí y no llegas a tener runners corriendo sin vigilancia
efectiva. El orden interno no es negociable en el otro sentido —`configurar-avisos.sh` necesita el
`./vigia/hooks.d` que crea `deploy.sh`—, pero el arranque sí se puede dejar para el final, y ahí es
donde importa.

**Es re-ejecutable**: en la segunda pasada reusa la configuración de avisos que ya escribió y no
vuelve a preguntarte nada.

> **Token.** `deploy.sh` necesita un **PAT** con *Administration: Read and write* sobre
> `demeneghi/sherman-svelte` (con él acuña los registration-tokens). **Por eso el comando
> no lleva `--token`**: lo resuelve en orden `--token` → `$ACCESS_TOKEN` → `gh auth token`
> → y si no, **te lo pregunta**, para que no quede en el history. Para pasarlo sin
> interacción, antepón `ACCESS_TOKEN=github_pat_…` o añade `--token github_pat_…`.
>
> **Labels.** GitHub ya añade `self-hosted`, `Linux` y la arquitectura solo; el label
> propio del proyecto es **`sherman`** (aquí `self-hosted` va explícito por claridad).
> `deploy.sh` añade además `host:<hostname>`, para saber en qué máquina vive cada runner.
>
> **Bootstrap.** Instala podman + un proveedor de compose y crea la machine si faltan
> (`--no-bootstrap` para omitirlo). `curl -f` corta la cadena si la descarga falla, y
> Compose se niega a arrancar si el YAML llega corrupto.
>
> **Sin avisos, si prefieres.** Quita el último tramo y `--vigilar`: los runners se
> despliegan igual. Pero entonces vuelves a no enterarte de que el fleet se cayó, que es
> justo lo que costó un día de trabajo el 1 de agosto.

**Cómo sube Verdaccio (importante).** `deploy.sh` genera `compose.yaml` y lo levanta
con `up -d` **sin `-f`**. Con el **plugin de Compose v2** (`podman compose` /
`docker compose`) eso **autofusiona** `compose.override.yaml` del directorio, así que
Verdaccio arranca junto a los runners en la red por defecto del proyecto —
alcanzable por nombre, sin `--network`.

> ⚠️ El **`podman-compose` legacy (Python)** —que el bootstrap de `deploy.sh` instala
> por defecto en hosts apt— **NO autofusiona** el override. Si es tu caso, instala el
> plugin de Compose v2, o levanta el stack a mano con:
>
> ```bash
> podman compose -f compose.yaml -f compose.override.yaml up -d
> ```

### Windows (PowerShell)

Mismo flujo con `deploy.ps1`. El operador `&&` necesita **PowerShell 7+** (en 5.1 corre
las dos instrucciones por separado). El token igual que en bash: `-Token`,
`$env:ACCESS_TOKEN`, `gh auth token`, o te lo pregunta.

```powershell
$ovr = 'https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/compose.override.yaml'
$dep = 'https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.ps1'

Invoke-WebRequest -UseBasicParsing $ovr -OutFile compose.override.yaml &&
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing $dep).Content)) `
    -Repo 'demeneghi/sherman-svelte' `
    -Image 'ghcr.io/joseamador95/sherman-svelte-runner:latest' `
    -Labels 'sherman,self-hosted' `
    -Count 3 -Vigilar -Up
```

Los **avisos** se configuran aparte en Windows: `configurar-avisos.sh` es un script POSIX y lo
ejecuta `sh.exe` de Git Bash, el mismo requisito que ya tiene el vigía ahí.

```powershell
sh.exe -c "$(Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/scripts/configurar-avisos.sh' | Select-Object -ExpandProperty Content)"
```

## Mantenerlo al día

- La imagen se reconstruye a diario en el CI (hereda `gh_runner:latest`).
- En el host, corre el `refresh.sh` de gh_runner periódicamente (cron): hace `pull` +
  `up -d` (recrea con la imagen nueva; con el plugin re-fusiona el override, así que
  Verdaccio también se actualiza). `--pull-always` ya es el **default** de `deploy.sh`,
  de modo que cada `up -d` re-baja `:latest`.

```bash
# cron en el host, desde el directorio del despliegue:
sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/refresh.sh)"
```

## Vigilancia del fleet

**Por qué importa tanto.** La CI de la app apunta al fleet **fijo, sin respaldo de pago**: con el
fleet caído sus jobs se quedan **en cola** en vez de irse a `ubuntu-latest`, así que nadie se entera
por la factura ni por una corrida roja. Enterarse es trabajo de la vigilancia, y de nada más.

Son **dos capas**, y cada una ve lo que la otra no:

| | Dónde corre | Cada | Lo que solo ve ella |
|---|---|---|---|
| **Vigía de GitHub** (`vigilar-runners.yml`) | Actions | 1 h | Un runner registrado **sin la etiqueta** del fleet: vivo, pero sin tomar jobs. Y cruza **todas** las máquinas de una vez |
| **Vigía del cluster** (servicio `vigia`, de gh_runner) | un contenedor **dentro de cada cluster** | 5 min | El runner **atascado** y el **reloj desfasado** — invisibles desde GitHub, donde el runner figura *online*. Y, por ausencia de latido, que la **máquina esté apagada** |

Ninguna sustituye a la otra. La de GitHub mira el fleet **desde fuera** y por eso ve el registro
entero; la del host mira **desde dentro** y por eso ve el proceso.

### Capa 1 — Vigía de GitHub (este repo)

`vigilar-runners.yml` corre **cada hora** y avisa por **Telegram** cuando cambia el estado del
fleet: alguno se cayó, alguno desapareció del registro, o volvieron todos. Solo habla cuando el
estado **cambia** respecto a la ronda anterior, así que una máquina apagada el fin de semana manda
un mensaje, no cuarenta.

**Por qué vive en este repo y no en el de la app.** Este repo es **público**, y en repos públicos
los minutos de los runners de GitHub son gratis; en `demeneghi/sherman-svelte`, que es privado, el
mismo cron se facturaría cada hora.

Ir por reloj y no por corrida es justo lo que lo hace útil: cubre noches y fines de semana, cuando
nadie empuja código y la CI no corre — que es cuando el fleet se cae sin que nadie mire.

#### Configuración

En **Settings → Secrets and variables → Actions** de este repo:

| Secret | Qué es |
|--------|--------|
| `SHERMAN_PAT` | Fine-grained PAT de **demeneghi**, *Repository access* → **solo** `demeneghi/sherman-svelte`, *Permissions → Repository → Administration:* **Read-only**. Con solo lectura puede **listar** runners pero **no** registrarlos ni borrarlos. Ponle caducidad y rótalo. |
| `TELEGRAM_BOT_TOKEN` | El bot que manda el aviso. |
| `TELEGRAM_CHAT_ID` | Chat destino, o **varios separados por coma** (ver abajo). |
| `TELEGRAM_THREAD_ID` | Opcional; solo para grupos con temas, y solo si hay **un** destino. |

**Avisar a varias personas.** Un **grupo** con el bot dentro es lo más cómodo: un solo id y añadir o
quitar gente no toca los secretos. Si prefieres mensajes privados, `TELEGRAM_CHAT_ID` acepta una
lista —`123456789,987654321`— y cada persona debe **haberle escrito antes al bot** (un bot no puede
escribir primero). Si un destino falla, el envío sigue con los demás y el log dice cuál falló. Un
destino puede fijar su tema con `id:hilo` (p. ej. `-1001234567890:12`).

> ⚠️ **Este repo es público y su dueño es `JoseAmador95`.** GitHub no pasa los secrets a los PR de
> forks, así que por ahí no se filtran, pero **quien tenga permiso de escritura puede leerlos**
> añadiendo un workflow. Por eso el PAT es de mínimo privilegio: lo peor que permite es ver los
> nombres de los runners. Si no quieres repartir esa confianza, el mismo vigía en un repo **público
> bajo `demeneghi`** cuesta igual (cero), o traspasa este repo a `demeneghi` como ya contempla la
> nota de arriba.

Variables opcionales (con valor por defecto): `REPO_VIGILADO` (`demeneghi/sherman-svelte`),
`CI_RUNNER_LABEL` (`sherman`), `RUNNERS_ESPERADOS` (`7`). `RUNNERS_ESPERADOS` es lo que detecta un
runner que **desapareció del listado** (contenedor muerto del todo), no solo uno `offline`.

#### Probarlo

Desde **Actions → vigilar-runners → Run workflow**, marcando la casilla **«Mandar el aviso aunque el
estado no haya cambiado»**.

Esa casilla es la que hace útil el disparo manual. Sin ella el anti-spam se aplica igual, así que si
el fleet está como en la ronda anterior el job sale **verde y en silencio** — y eso no se distingue de
tener los secretos mal puestos. Con la casilla marcada llega el mensaje sí o sí, y si lo lees, el
cableado funciona. No descoloca nada: el estado se registra igual, así que la ronda siguiente vuelve a
comparar con normalidad.

En local, sin enviar nada:

```bash
SHERMAN_PAT=github_pat_… node scripts/vigilar-runners.mjs \
  --repo=demeneghi/sherman-svelte --esperados=7 --dry-run
```

Añade `--forzar` para ver el mensaje que mandaría aunque no haya cambios.

Cambiar la cadencia es cambiar la línea del `cron` en el workflow. Si la API de GitHub falla, el
vigía lo registra y sale en verde **sin** avisar: un mal minuto de GitHub no es un fleet caído.

### Capa 2 — Vigía del host (en cada máquina)

Detecta lo que desde GitHub **no se ve**: el runner que sigue `Up` pero **atascado** sin poder
hablar con GitHub (figura *online* en el registro y no toma un solo job), el contenedor ausente, y
el **reloj desfasado** —la causa raíz del incidente del 1 de agosto, en que un host iba 32 minutos
atrasado y sus runners quedaron inservibles durante horas—.

Lo añade el **`--vigilar`** del comando de [Desplegar](#desplegar), que mete al compose el servicio
**`vigia`** y deja los hooks de aviso **como ejemplos**, sin activar: el vigía ya vigila, pero
todavía no sabe por dónde avisarte. De eso se encarga el último tramo de ese mismo comando.

Es **un contenedor más del cluster**, no un servicio del sistema: sube y baja con `up -d` / `down`,
funciona igual en Linux, macOS y Windows, y si la máquina se apaga cae con ella — que es justo lo
que dispara el aviso por ausencia. Para verlo:

```bash
podman compose logs -f vigia
```

**Con varios clusters en una misma máquina**, cada uno lleva su propio vigía y su propio check, y
el nombre del cluster (el del directorio del despliegue) encabeza cada aviso. No hay nada que
configurar para eso.

#### Configurar los avisos

Va incluido en el comando de despliegue. Para (re)configurarlos por separado —cambiar de proyecto,
rotar la ping key— es el mismo script suelto:

```bash
sh scripts/configurar-avisos.sh
```

Córrelo **en el directorio del despliegue**. Te pregunta la *ping key* de healthchecks.io, escribe
`./vigia/avisos.conf` (**chmod 600**), activa el hook y **manda una prueba**. Reusa lo que ya hubiera
guardado, así que solo tienes que responder lo que quieras cambiar.

**Telegram no se configura aquí: se configura en healthchecks.io.** Su notificación **reenvía el
informe entero** en monospace, más el estado de los demás checks — que con varios clusters es justo
lo que quieres ver. Así el token del bot no vive en ninguna máquina y cambiar a quién avisas no
exige tocar el fleet.

La **ping key es del proyecto**, no de un check: la misma sirve para todas las máquinas, y el check
**de cada máquina** se crea solo en su primer ping (el nombre lleva cluster y host, así que dos Macs
no comparten check — si lo compartieran, el latido sano de uno lo mantendría verde con el otro
muerto). Si además le das una **API key**, el vigía deja
ese check con el periodo y el margen correctos —**10 y 5 minutos**, derivados de la cadencia de la
ronda—; si no, ajústalos a mano una vez, y el script te lo recuerda con los números exactos. El check
autocreado nace con **periodo de 1 día**, y con eso un host caído tardaría un día en avisar.

Esa prueba es el motivo de que exista el script. Un aviso mal cableado **no falla: calla** — y
callar es exactamente lo que hace un fleet sano. Sin probarlo al instalarlo, el fallo aparece la
noche que algo se rompe, que es cuando ya no sirve de nada.

Para automatizar varias máquinas, los valores también salen del entorno:

```bash
HC_PING_KEY=… sh scripts/configurar-avisos.sh --no-preguntar
```

> ⚠️ Por defecto **pregunta** en vez de aceptar banderas, igual que `deploy.sh` con el PAT: así la
> clave no queda en el historial del shell. Con `--no-preguntar` sí queda — úsalo solo desde un
> script de aprovisionamiento.

Una vez configurada una máquina, replicarla es copiar **un solo fichero** — y con ping key el
contenido es **idéntico** en todas, porque el check lo identifica el nombre del cluster:

```bash
scp ./vigia/avisos.conf otro-host:~/ruta-del-despliegue/vigia/
```

Los hooks lo leen solos; no hay que editarlos en cada host.

> **Los secretos no viven en este repo, y no pueden: es público.** Los `TELEGRAM_*` de
> *Settings → Secrets* son para la **capa 1** (Actions) y GitHub no se los puede entregar a una
> máquina. El repo aporta la lógica; el secreto lo pones tú en el host, una vez.

#### Qué avisos llegan

Solo cuando el estado **cambia**, nunca en cada ronda:

| Cuándo | Mensaje |
|---|---|
| Primera ronda tras instalar | 🔎 **Vigilancia activa** — confirma que el cableado funciona |
| Algo se rompe | 🔴 **Runners en problemas** + qué runner y por qué |
| Vuelve a estar bien | ✅ **Runners de vuelta** |
| Nada cambió | *silencio* |

Y el aviso que **no** puede llegar por Telegram: que la máquina esté apagada. Nadie manda un mensaje
desde un host muerto. Eso lo cubre healthchecks.io **por ausencia de latido** — el host hace ping
cada ronda y es el servicio quien avisa cuando deja de llegar. Con rondas de 5 min, pon *period* ~15
min y *grace* ~10 en el check.

## En los workflows de Sherman-svelte

> **Ya está cableado.** `ci.yml` y `e2e-suite.yml` de `demeneghi/sherman-svelte` fijan
> `runs-on: [self-hosted, linux, sherman]` en **todos** sus jobs, sin selector ni respaldo de pago.
> Hubo un job que elegía runner por corrida y se retiró: costaba un minuto facturado en cada corrida
> por cubrir solo el caso «el fleet ya estaba apagado al arrancar». Con el fleet caído los jobs se
> **encolan**, y de eso avisa el vigía de arriba. Lo de abajo es el porqué de cada pieza.

Para aprovechar el runner y no pelear con el cache remoto de GitHub:

- **Apunta el job al runner:** `runs-on: [self-hosted, linux, sherman]` (`sherman` = tu label de `--labels`). Ojo: sin respaldo, un pipeline que **no** pueda quedarse en cola (un aviso que tiene que llegar sí o sí) es justo el que debe quedarse en `ubuntu-latest`.
- **Quita `actions/cache` y `setup-node` con `cache: pnpm`.** El store de pnpm ya
  persiste en `_work` (local, mismo filesystem que `node_modules`). Esos pasos
  suben/bajan el store al cache de GitHub (Azure) — lento y redundante; son el
  paso **"post"** que veías. Al quitarlos, desaparece.
- Instala con `pnpm install --frozen-lockfile --prefer-offline`.
- **(Opcional) Verdaccio local:** `npm_config_registry=http://verdaccio:4873`.
- `actions/checkout` reutiliza el `.git` persistente en `_work` (fetch incremental);
  mantén `fetch-depth` bajo.
- **Playwright:** las libs del sistema ya vienen en la imagen; en el job basta
  `pnpm exec playwright install` (baja los navegadores de la versión fijada; quedan
  cacheados en `~/.cache/ms-playwright`, volumen persistente).

```yaml
# .github/workflows/ci.yml (en el repo demeneghi/sherman-svelte)
jobs:
  test:
    runs-on: [self-hosted, linux, sherman]   # 'sherman' = tu label del --labels
    steps:
      - uses: actions/checkout@v4
      - run: corepack enable
      - run: pnpm install --frozen-lockfile --prefer-offline
      - run: pnpm run build
      - run: pnpm exec playwright install   # navegadores (libs ya en la imagen)
      - run: pnpm test
```

## Por qué imagen derivada (y no fork ni submódulo)

- **Fork de gh_runner** → divergiría del upstream; los arreglos del base no llegan solos.
- **Submódulo** → solo vendoriza `deploy.sh`; no resuelve el toolchain (que va en la imagen).
- **Imagen derivada (`FROM`)** → hereda el base por OCI: el `schedule` diario re-bajará
  el `gh_runner:latest` actualizado y tú solo mantienes la capa del proyecto. ✅
