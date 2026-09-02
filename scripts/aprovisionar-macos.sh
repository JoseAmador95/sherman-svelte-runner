#!/bin/sh
# ============================================================================
# aprovisionar-macos.sh — toolchain de Sherman-svelte DENTRO de la VM "golden"
# de macOS. Es el equivalente exacto, para el camino macOS, de lo que el
# `Containerfile` de este repo hace para el camino Linux: parte de una base
# genérica y añade solo lo específico del proyecto.
#
# Quién lo ejecuta y cuándo: NO se corre a mano. Lo invoca
# `hornear-macos.sh --completo --provisionar <esta URL o ruta>` (del repo
# `gh_runner`), que lo copia o descarga DENTRO de la VM golden y lo ejecuta por
# ssh una sola vez, antes de apagarla y congelarla. De ahí en adelante, cada
# job clona esa golden ya aprovisionada (`tart clone` → `tart run` → job →
# `tart delete`); este script no vuelve a correr hasta el próximo horneado
# semanal.
#
# Qué instala y por qué (versiones ancladas a lo que fija el proyecto
# `sherman-svelte`, igual que el `ARG NODE_MAJOR=22` del Containerfile):
#   - Homebrew: gestor de paquetes; puede faltar del PATH de una sesión ssh no
#     interactiva aunque esté instalado, así que se resuelve explícitamente en
#     vez de asumirlo.
#   - Node 22 (fija `.node-version` / `engines.node` de la app) vía Homebrew.
#   - pnpm 10.29.3 (fija `packageManager` de la app) vía corepack, que ya
#     trae Node — igual que el Containerfile.
#   - Rust estable + target `aarch64-apple-darwin`: hoy `escritorio-build.yml`
#     y `escritorio-release.yml` lo instalan por job con
#     `dtolnay/rust-toolchain@stable`; esa acción detecta un rustup ya
#     presente con el toolchain y el target puestos y se salta la descarga,
#     así que hornearlo aquí ahorra ese tiempo en cada corrida sin romper
#     nada si algún día cambia.
#   - `xcodebuild` (para el archivo de iOS de `movil-release.yml` y, junto con
#     Rust, para el bundler de Tauri) NO se instala: ya viene en la imagen
#     base de Cirrus (`macos-sequoia-xcode`) que clona `hornear-macos.sh`. Este
#     script solo lo VERIFICA — si faltara, hornear con otra base sin Xcode es
#     el defecto real, y hay que decirlo alto, no intentar instalar Xcode aquí.
#
# NO se hornean certificados de firma ni llaves privadas: `movil-release.yml`
# ya monta un llavero temporal desde los secretos EN CADA CORRIDA, que es lo
# correcto en una VM efímera — hornear un certificado en la golden lo dejaría
# expuesto en todos los clones que salgan de ella.
#
# Falla ruidosamente y pronto: la golden se congela justo después de correr
# este script, así que un fallo silencioso aquí no se descubre hasta el primer
# job real, con el runner ya en producción. Por eso el script termina
# VERIFICANDO cada herramienta y aborta con `set -eu` más un mensaje explícito
# si algo no quedó instalado como se esperaba.
#
# Idempotente: `hornear-macos.sh --completo` es semanal y se puede reintentar
# tras un fallo a mitad de camino. Cada paso comprueba primero si ya está
# satisfecho (versión correcta ya instalada) antes de instalar o descargar
# nada, así que correrlo dos veces seguidas no reinstala ni duplica trabajo.
#
# POSIX sh a propósito, sin `local` (igual que los scripts de gh_runner: se
# ejecuta con `sh archivo.sh`, no con bash).
# ============================================================================
set -eu

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# ---- Versiones ancladas al proyecto (ver `.node-version` / `package.json` en
# sherman-svelte) --------------------------------------------------------
NODE_MAJOR_ESPERADO="22"
PNPM_VERSION_ESPERADA="10.29.3"
RUST_TARGET="aarch64-apple-darwin"

# ---- Homebrew: resolver el PATH sin asumir nada -----------------------------
# En una sesión ssh no interactiva `brew` puede faltar del PATH aunque esté
# instalado: el shell no interactivo no siempre carga el perfil de login que
# lo publica, y en Apple Silicon vive en /opt/homebrew/bin, no en /usr/local.
resolver_brew() {
    if command -v brew >/dev/null 2>&1; then
        return 0
    fi
    for candidato in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidato" ]; then
            eval "$("$candidato" shellenv)"
            return 0
        fi
    done
    info "Homebrew no aparece instalado; instalando (no interactivo)..."
    command -v curl >/dev/null 2>&1 || err "falta 'curl', necesario para instalar Homebrew."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || err "el instalador de Homebrew terminó con error."
    for candidato in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidato" ]; then
            eval "$("$candidato" shellenv)"
            return 0
        fi
    done
    err "Homebrew se instaló pero no encuentro su binario en /opt/homebrew/bin ni /usr/local/bin."
}

# Persistir el PATH de Homebrew para las sesiones futuras que arranquen un
# shell de login (zsh es el shell por defecto en macOS desde Catalina). Es
# best-effort e idempotente: solo añade la línea si no está ya.
persistir_brew_en_perfil() {
    zprofile="$HOME/.zprofile"
    linea="eval \"\$($BREW_BIN shellenv)\""
    touch "$zprofile"
    grep -Fq "$BREW_BIN shellenv" "$zprofile" 2>/dev/null || printf '%s\n' "$linea" >> "$zprofile"
}

resolver_brew
BREW_BIN="$(command -v brew)"
persistir_brew_en_perfil

# ---- Node 22 vía Homebrew ---------------------------------------------------
node_mayor_instalado() {
    command -v node >/dev/null 2>&1 || return 1
    node --version | sed 's/^v//' | cut -d. -f1
}

instalar_node() {
    _mayor="$(node_mayor_instalado || true)"
    if [ "$_mayor" = "$NODE_MAJOR_ESPERADO" ]; then
        info "Node $(node --version) ya está instalado; no se reinstala."
        return 0
    fi
    info "Instalando Node ${NODE_MAJOR_ESPERADO} vía Homebrew..."
    brew install "node@${NODE_MAJOR_ESPERADO}" || err "no pude instalar node@${NODE_MAJOR_ESPERADO} con Homebrew."
    brew link --overwrite --force "node@${NODE_MAJOR_ESPERADO}" \
        || err "no pude enlazar node@${NODE_MAJOR_ESPERADO} (brew link)."
}
instalar_node

# ---- pnpm vía corepack (ya viene con Node) ----------------------------------
pnpm_version_instalada() {
    command -v pnpm >/dev/null 2>&1 || return 1
    pnpm --version 2>/dev/null
}

habilitar_pnpm() {
    if [ "$(pnpm_version_instalada || true)" = "$PNPM_VERSION_ESPERADA" ]; then
        info "pnpm ${PNPM_VERSION_ESPERADA} ya está activo; no se reinstala."
        return 0
    fi
    command -v corepack >/dev/null 2>&1 || err "falta 'corepack' (debería venir con Node ${NODE_MAJOR_ESPERADO})."
    corepack enable || err "'corepack enable' terminó con error."
    # COREPACK_ENABLE_DOWNLOAD_PROMPT=0: aprovisiona el pnpm fijado por el
    # proyecto sin bloquearse en un prompt interactivo (mismo criterio que el
    # Containerfile de Linux).
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare "pnpm@${PNPM_VERSION_ESPERADA}" --activate \
        || err "no pude activar pnpm@${PNPM_VERSION_ESPERADA} con corepack."
}
habilitar_pnpm

# ---- Rust estable + target aarch64-apple-darwin -----------------------------
instalar_rust() {
    if command -v rustup >/dev/null 2>&1; then
        info "rustup ya está instalado; no se reinstala."
    else
        info "Instalando rustup (toolchain estable) vía Homebrew..."
        brew install rustup-init || err "no pude instalar rustup-init con Homebrew."
        rustup-init -y --profile minimal --default-toolchain stable \
            || err "'rustup-init' terminó con error."
    fi
    # rustup-init modifica el perfil de shell para publicar ~/.cargo/bin, pero
    # esta MISMA sesión no lo ha releído: se añade a mano para lo que sigue.
    export PATH="$HOME/.cargo/bin:$PATH"
    command -v rustup >/dev/null 2>&1 \
        || err "rustup se instaló pero no aparece en \$HOME/.cargo/bin tras instalarlo."

    rustup toolchain install stable --profile minimal \
        || err "no pude instalar el toolchain 'stable' de Rust."
    rustup target add "$RUST_TARGET" \
        || err "no pude añadir el target '${RUST_TARGET}' de Rust."
}
instalar_rust

# ---- Verificación final: falla alto y claro si algo no quedó instalado -----
# La golden se congela justo después de este script; un hueco silencioso aquí
# se descubre en el primer job real, con el runner ya en producción.
verificar() {
    _faltan=""

    if ! command -v node >/dev/null 2>&1; then
        _faltan="${_faltan}\n  - node: no está en el PATH."
    elif [ "$(node_mayor_instalado || true)" != "$NODE_MAJOR_ESPERADO" ]; then
        _faltan="${_faltan}\n  - node: se esperaba la versión mayor ${NODE_MAJOR_ESPERADO}, hay $(node --version)."
    fi

    if ! command -v pnpm >/dev/null 2>&1; then
        _faltan="${_faltan}\n  - pnpm: no está en el PATH."
    elif [ "$(pnpm_version_instalada || true)" != "$PNPM_VERSION_ESPERADA" ]; then
        _faltan="${_faltan}\n  - pnpm: se esperaba ${PNPM_VERSION_ESPERADA}, hay $(pnpm --version)."
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        _faltan="${_faltan}\n  - cargo: no está en el PATH (\$HOME/.cargo/bin)."
    fi

    if ! command -v xcodebuild >/dev/null 2>&1; then
        _faltan="${_faltan}\n  - xcodebuild: no está instalado (¿la imagen base de 'hornear-macos.sh --base' trae Xcode?)."
    fi

    if [ -n "$_faltan" ]; then
        printf 'ERROR: el aprovisionamiento dejó herramientas sin instalar:%b\n' "$_faltan" >&2
        exit 1
    fi

    info "Verificado: node $(node --version), pnpm $(pnpm --version), $(cargo --version), $(xcodebuild -version | head -n1)."
}
verificar

info "Aprovisionamiento de macOS para sherman-svelte completado."
