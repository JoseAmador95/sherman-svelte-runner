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
       --labels svelte \
       --count 3 --up
```

> `deploy.sh` hace **bootstrap** del entorno por defecto (instala podman + un proveedor
> de compose y crea la machine si faltan); usa `--no-bootstrap` para gestionarlo tú.
> `curl -f` corta la cadena si la descarga falla, y Compose se niega a arrancar si el
> YAML llega corrupto.

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

En Windows usa `deploy.ps1` con
`-Image ghcr.io/joseamador95/sherman-svelte-runner:latest -Labels svelte`.

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

## En los workflows de Sherman-svelte

Para aprovechar el runner y no pelear con el cache remoto de GitHub:

- **Apunta el job al runner:** `runs-on: [self-hosted, linux, svelte]` (`svelte` = la label de `--labels`).
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
    runs-on: [self-hosted, linux, svelte]   # 'svelte' = la label del --labels
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
