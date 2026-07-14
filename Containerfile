# Runner de la CI de Sherman-svelte: imagen DERIVADA de gh_runner (genérico) +
# el toolchain del proyecto. gh_runner aporta el agente efímero, el auto-reinicio,
# el cache persistente y el entrypoint; aquí solo se añade lo específico.
#
# Build local (detecta la arch del host):   podman build -t sherman-svelte-runner:local .
# El CI la publica multi-arch en GHCR (ver .github/workflows/build-image.yml).

FROM ghcr.io/joseamador95/gh_runner:latest

# Enlaza el package de GHCR con este repo (procedencia/visibilidad). Es un fallback
# para builds locales: en el CI, docker/metadata-action sobreescribe este label con
# ${{ github.repository }}, así que se autocorrige tras el rename o el traspaso a demeneghi.
LABEL org.opencontainers.image.source="https://github.com/JoseAmador95/sherman-svelte-runner"

# ---- Toolchain del proyecto (Node LTS + pnpm vía corepack) -----------------
# NodeSource trae Node multi-arch (amd64/arm64); corepack (incluido en Node)
# habilita pnpm sin instalarlo aparte.
USER root
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && rm -rf /var/lib/apt/lists/*

# ---- Playwright: libs del sistema para los navegadores ---------------------
# La CI de Sherman-svelte usa Playwright. Aquí solo se HORNEAN las dependencias
# del SISTEMA; los navegadores se bajan EN EL JOB con `pnpm exec playwright install`
# (la versión la fija el proyecto) y quedan cacheados en ~/.cache/ms-playwright
# (el volumen .cache persistente por-runner) entre jobs.
RUN npx --yes playwright@latest install-deps \
    && rm -rf /var/lib/apt/lists/*

USER runner
WORKDIR /home/runner

# El store de pnpm DENTRO de _work: mismo filesystem que node_modules
# (_work/<repo>) → pnpm instala por hard-links, sin descargar. El cache de npm
# en .cache (ambos son volúmenes persistentes por-runner). Esto es específico
# del proyecto, por eso va aquí y NO en el gh_runner base (genérico).
# COREPACK_ENABLE_DOWNLOAD_PROMPT=0: corepack aprovisiona el pnpm fijado por el
# proyecto (packageManager: pnpm@10.29.3) sin bloquearse en un prompt interactivo.
ENV npm_config_store_dir=/home/runner/_work/.pnpm-store \
    npm_config_cache=/home/runner/.cache/npm \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# NO redefinimos ENTRYPOINT: se hereda el de gh_runner (registro efímero).
