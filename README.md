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
curl -fsSL -O https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/compose.override.yaml \
  && sh -c "$(curl -fsSL https://raw.githubusercontent.com/JoseAmador95/gh_runner/main/deploy.sh)" -- \
       --repo demeneghi/sherman-svelte \
       --image ghcr.io/joseamador95/sherman-svelte-runner:latest \
       --labels sherman,self-hosted \
       --count 3 --up
```

> **Token.** `deploy.sh` necesita un **PAT** con *Administration: Read and write* sobre
> `demeneghi/sherman-svelte` (con él acuña los registration-tokens). No va en el comando
> a propósito: lo resuelve en orden `--token` → `$ACCESS_TOKEN` → `gh auth token` → y si
> no, **te lo pregunta** (así no queda en el history). Para pasarlo sin interacción,
> antepón `ACCESS_TOKEN=github_pat_…` o añade `--token github_pat_…`.
>
> **Labels.** GitHub ya añade `self-hosted`, `Linux` y la arquitectura solo; el label
> propio del proyecto es **`sherman`** (aquí `self-hosted` va explícito por claridad).
>
> **Bootstrap.** Instala podman + un proveedor de compose y crea la machine si faltan
> (`--no-bootstrap` para omitirlo). `curl -f` corta la cadena si la descarga falla, y
> Compose se niega a arrancar si el YAML llega corrupto.

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
    -Count 3 -Up
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

`vigilar-runners.yml` corre **cada hora** y avisa por **Telegram** cuando cambia el estado del
fleet: alguno se cayó, alguno desapareció del registro, o volvieron todos. Solo habla cuando el
estado **cambia** respecto a la ronda anterior, así que una máquina apagada el fin de semana manda
un mensaje, no cuarenta.

**Por qué vive en este repo y no en el de la app.** Este repo es **público**, y en repos públicos
los minutos de los runners de GitHub son gratis; en `demeneghi/sherman-svelte`, que es privado, el
mismo cron se facturaría cada hora.

Se reparte el trabajo con el job `elegir-runner` del repo de la app:

| Quién | Cuándo avisa | Por qué ahí |
|-------|--------------|-------------|
| `elegir-runner` (repo de la app) | Una corrida **cae a runners de pago** | Ya está corriendo: el aviso sale gratis y llega en el momento en que empieza a costar dinero. |
| `vigilar-runners` (aquí) | **Falta** algún runner aunque el fleet siga sirviendo, o **vuelven** todos | Cubre noches y fines de semana, cuando nadie empuja código y la CI no corre. |

### Configuración

En **Settings → Secrets and variables → Actions** de este repo:

| Secret | Qué es |
|--------|--------|
| `SHERMAN_PAT` | Fine-grained PAT de **demeneghi**, *Repository access* → **solo** `demeneghi/sherman-svelte`, *Permissions → Repository → Administration:* **Read-only**. Con solo lectura puede **listar** runners pero **no** registrarlos ni borrarlos. Ponle caducidad y rótalo. |
| `TELEGRAM_BOT_TOKEN` | El bot que manda el aviso. |
| `TELEGRAM_CHAT_ID` | Chat destino. |
| `TELEGRAM_THREAD_ID` | Opcional; solo para grupos con temas. |

> ⚠️ **Este repo es público y su dueño es `JoseAmador95`.** GitHub no pasa los secrets a los PR de
> forks, así que por ahí no se filtran, pero **quien tenga permiso de escritura puede leerlos**
> añadiendo un workflow. Por eso el PAT es de mínimo privilegio: lo peor que permite es ver los
> nombres de los runners. Si no quieres repartir esa confianza, el mismo vigía en un repo **público
> bajo `demeneghi`** cuesta igual (cero), o traspasa este repo a `demeneghi` como ya contempla la
> nota de arriba.

Variables opcionales (con valor por defecto): `REPO_VIGILADO` (`demeneghi/sherman-svelte`),
`CI_RUNNER_LABEL` (`sherman`), `RUNNERS_ESPERADOS` (`7`). `RUNNERS_ESPERADOS` es lo que detecta un
runner que **desapareció del listado** (contenedor muerto del todo), no solo uno `offline`.

### Probarlo

Desde **Actions → vigilar-runners → Run workflow**, o en local sin enviar nada:

```bash
SHERMAN_PAT=github_pat_… node scripts/vigilar-runners.mjs \
  --repo=demeneghi/sherman-svelte --esperados=7 --dry-run
```

Cambiar la cadencia es cambiar la línea del `cron` en el workflow. Si la API de GitHub falla, el
vigía lo registra y sale en verde **sin** avisar: un mal minuto de GitHub no es un fleet caído.

## En los workflows de Sherman-svelte

> **Ya está cableado.** `ci.yml` de `demeneghi/sherman-svelte` no fija `runs-on` a mano: un job
> `elegir-runner` (`scripts/elegir-runner.mjs`) consulta la API, publica
> `["self-hosted","linux","sherman"]` si hay al menos un runner **en línea** —ocupado o no, porque
> esperar en la cola del fleet es gratis y caer a `ubuntu-latest` cuesta— y cae al respaldo de pago
> solo cuando el fleet no responde, avisando por Telegram. Lo de abajo es el porqué de cada pieza.

Para aprovechar el runner y no pelear con el cache remoto de GitHub:

- **Apunta el job al runner:** `runs-on: [self-hosted, linux, sherman]` (`sherman` = tu label de `--labels`), o al selector con respaldo si el pipeline no puede quedarse en cola.
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
