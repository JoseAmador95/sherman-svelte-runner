#!/bin/sh
# ============================================================================
# configurar-avisos.sh — deja listos los avisos del vigía en ESTA máquina.
#
# El vigía (gh_runner: `deploy.sh --vigilar`) detecta runners atascados, caídos
# y el reloj desfasado, pero NO decide cómo te avisa: eso lo hacen los hooks, y
# cada hook necesita su credencial. Este script hace ese último tramo sin que
# tengas que editar ficheros a mano en cada host:
#
#   1. Escribe ~/.config/gh-runner/avisos.conf (chmod 600) con tus valores.
#   2. Activa los hooks que correspondan (copia el .ejemplo sin el sufijo).
#   3. MANDA UNA PRUEBA por cada canal configurado.
#
# El paso 3 es el que de verdad importa. Un aviso mal cableado no falla: calla,
# y calla exactamente igual que un fleet sano. Si no lo pruebas al instalarlo,
# te enteras la noche que se cae algo — que es cuando ya no sirve.
#
# LOS SECRETOS NO VIVEN EN ESTE REPO, y no pueden: es público. Los pones tú al
# ejecutarlo, y se quedan solo en el host.
#
# Uso recomendado (te pregunta lo que falte, sin dejar nada en el history):
#   sh scripts/configurar-avisos.sh
#
# Desatendido (ojo: los valores quedan en el historial del shell):
#   HC_URL=… TG_TOKEN=… TG_CHAT=… sh scripts/configurar-avisos.sh --no-preguntar
#
# Un solo canal también vale: deja el otro en blanco y no se toca.
# ============================================================================
set -eu

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

HOOKS_DIR="${VIGILAR_HOOKS:-${XDG_CONFIG_HOME:-$HOME/.config}/gh-runner/hooks.d}"
CONF="${VIGILAR_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/gh-runner/avisos.conf}"
PREGUNTAR="si"
PROBAR="si"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --hc-url)           HC_URL="${2:?}"; shift 2 ;;
        --telegram-token)   TG_TOKEN="${2:?}"; shift 2 ;;
        --telegram-chat)    TG_CHAT="${2:?}"; shift 2 ;;
        --telegram-thread)  TG_THREAD="${2:?}"; shift 2 ;;
        --hooks)            HOOKS_DIR="${2:?}"; shift 2 ;;
        --conf)             CONF="${2:?}"; shift 2 ;;
        --no-preguntar)     PREGUNTAR="no"; shift ;;
        --no-probar)        PROBAR="no"; shift ;;
        -h|--help)
            # Con `sh -c "$(curl …)"` el script no está en disco y $0 es "sh",
            # así que la cabecera no se puede leer: resumen corto de respaldo.
            if [ -r "$0" ]; then
                sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2
            else
                info 'Uso: configurar-avisos.sh [opciones]'
                info '  --hc-url URL            Ping de healthchecks.io (env: HC_URL)'
                info '  --telegram-token TOKEN  Bot de Telegram          (env: TG_TOKEN)'
                info '  --telegram-chat ID      Chat destino             (env: TG_CHAT)'
                info '  --telegram-thread ID    Tema del grupo, opcional (env: TG_THREAD)'
                info '  --hooks RUTA            Dir de hooks del vigía'
                info '  --conf RUTA             Dónde guardar la configuración'
                info '  --no-preguntar          No preguntar lo que falte'
                info '  --no-probar             No mandar la prueba por cada canal'
            fi
            exit 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

HC_URL="${HC_URL:-}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT="${TG_CHAT:-}"
TG_THREAD="${TG_THREAD:-}"

command -v curl >/dev/null 2>&1 || err "hace falta 'curl'."

# ---- Reusar lo ya configurado ----------------------------------------------
# Sin esto, volver a ejecutar (por ejemplo si el comando de despliegue lo
# encadena) pediría el token OTRA VEZ en cada re-deploy. Precedencia final:
# bandera > entorno > lo que ya había en el fichero > preguntar.
_hc="$HC_URL"; _tt="$TG_TOKEN"; _tc="$TG_CHAT"; _th="$TG_THREAD"
YA_HABIA="no"
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF" || err "no pude leer $CONF (¿está corrupto?)."
    YA_HABIA="si"
fi
[ -n "$_hc" ] && HC_URL="$_hc"
[ -n "$_tt" ] && TG_TOKEN="$_tt"
[ -n "$_tc" ] && TG_CHAT="$_tc"
[ -n "$_th" ] && TG_THREAD="$_th"
[ "$YA_HABIA" = "si" ] && info "Reusando lo que ya había en $CONF (una bandera o variable de entorno lo sustituye)."

# ---- Preguntar lo que falte ------------------------------------------------
# Igual que deploy.sh con el PAT: preguntar es el camino por defecto, para que
# el secreto no acabe en el historial del shell.
preguntar() {  # $1 = texto
    [ -t 0 ] || return 0
    printf '%s' "$1" >&2
    read -r _r || _r=""
    printf '%s' "$_r"
}

if [ "$PREGUNTAR" = "si" ] && [ -t 0 ]; then
    info "Deja en blanco cualquier canal que no quieras configurar."
    info ""
    [ -n "$HC_URL" ]   || HC_URL="$(preguntar 'URL de ping de healthchecks.io: ')"
    [ -n "$TG_TOKEN" ] || TG_TOKEN="$(preguntar 'Token del bot de Telegram: ')"
    if [ -n "$TG_TOKEN" ]; then
        [ -n "$TG_CHAT" ]   || TG_CHAT="$(preguntar 'Chat id de Telegram: ')"
        [ -n "$TG_THREAD" ] || TG_THREAD="$(preguntar 'Id del tema (opcional, Enter para omitir): ')"
    fi
fi

[ -n "$HC_URL$TG_TOKEN" ] || err "no configuraste ningún canal; no hay nada que hacer."

# ---- Validaciones de forma (baratas, y ahorran un susto) -------------------
if [ -n "$HC_URL" ]; then
    case "$HC_URL" in
        https://*) : ;;
        *) err "la URL de ping debe empezar por https:// (llegó: '$HC_URL')" ;;
    esac
fi
if [ -n "$TG_TOKEN" ]; then
    [ -n "$TG_CHAT" ] || err "con token de Telegram hace falta también el chat id."
    # El token de BotFather es <digitos>:<resto>. Un token pegado a medias es la
    # causa nº 1 de "no me llegan los avisos", y aquí cuesta una línea verlo.
    case "$TG_TOKEN" in
        [0-9]*:?*) : ;;
        *) err "el token del bot no tiene la forma <numero>:<resto> (¿lo pegaste entero?)" ;;
    esac
fi

# ---- Escribir la configuración --------------------------------------------
# Entre comillas simples y escapando las que traiga el valor: los hooks hacen
# `.` sobre este fichero, así que un valor sin escapar sería ejecutable.
entrecomillar() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

umask 077
mkdir -p "$(dirname "$CONF")"
{
    printf '# GENERADO por configurar-avisos.sh — valores de los hooks del vigía.\n'
    printf '# Contiene credenciales: chmod 600 y NUNCA se commitea.\n'
    [ -n "$HC_URL" ]    && printf 'HC_URL=%s\n' "$(entrecomillar "$HC_URL")"
    [ -n "$TG_TOKEN" ]  && printf 'TG_TOKEN=%s\n' "$(entrecomillar "$TG_TOKEN")"
    [ -n "$TG_CHAT" ]   && printf 'TG_CHAT=%s\n' "$(entrecomillar "$TG_CHAT")"
    [ -n "$TG_THREAD" ] && printf 'TG_THREAD=%s\n' "$(entrecomillar "$TG_THREAD")"
    :
} > "$CONF"
chmod 600 "$CONF"
info "Escrito $CONF (chmod 600)."

# ---- Activar los hooks -----------------------------------------------------
# Los hooks los instala `deploy.sh --vigilar` con sufijo .ejemplo, para que no
# se ejecuten a medio configurar. Activarlos es quitarles el sufijo.
[ -d "$HOOKS_DIR" ] || err "no existe $HOOKS_DIR.
       Instala antes el vigía:  sh deploy.sh … --vigilar   (o pasa --hooks RUTA)"

activar() {  # $1 = nombre del hook
    _act="${HOOKS_DIR}/$1"
    if [ -e "$_act" ]; then
        info "  $1 ya estaba activo (no lo toco: puede que lo hayas ajustado)."
        return 0
    fi
    [ -e "${_act}.ejemplo" ] || { info "  AVISO: no encuentro ${_act}.ejemplo; sáltate este canal."; return 0; }
    cp "${_act}.ejemplo" "$_act"
    chmod 700 "$_act"
    info "  $1 activado."
}

info "Hooks en $HOOKS_DIR:"
[ -n "$HC_URL" ]   && activar 10-healthchecks.sh
[ -n "$TG_TOKEN" ] && activar 20-telegram.sh

# ---- Probar de verdad ------------------------------------------------------
# Un canal mal cableado calla igual que un fleet sano: si no se prueba ahora, el
# fallo aparece la noche que algo se rompe.
if [ "$PROBAR" != "si" ]; then
    info ""
    info "Listo (sin probar). Para comprobarlo: systemctl --user start gh-runner-vigilar.service"
    exit 0
fi

info ""
info "Probando los canales..."
_fallos=0

if [ -n "$HC_URL" ]; then
    # Ping normal, NUNCA /fail: una prueba no debe dejar el check en rojo ni
    # despertar a nadie. Basta con que healthchecks.io lo registre.
    if curl -fsS -m 15 --retry 2 -X POST -H 'Content-Type: text/plain; charset=utf-8' \
            --data-raw 'Prueba de configurar-avisos.sh: el canal funciona.' \
            "$HC_URL" >/dev/null 2>&1; then
        info "  healthchecks.io: OK (míralo en el panel del check)."
    else
        info "  healthchecks.io: FALLÓ. Revisa la URL de ping."
        _fallos=$(( _fallos + 1 ))
    fi
fi

if [ -n "$TG_TOKEN" ]; then
    _host="$(hostname 2>/dev/null || echo host)"
    set -- --data-urlencode "chat_id=${TG_CHAT}" \
           --data-urlencode "text=🔧 Avisos configurados en ${_host%%.*}. Este es el canal por el que llegarán las alertas del fleet."
    [ -n "$TG_THREAD" ] && set -- "$@" --data-urlencode "message_thread_id=${TG_THREAD}"
    if curl -fsS -m 15 --retry 2 -X POST "$@" \
            "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1; then
        info "  Telegram: OK (mira el chat)."
    else
        info "  Telegram: FALLÓ. Token, chat id, o el bot no puede publicar en ese chat."
        info "    Recuerda: un bot no puede escribir primero a una persona; en grupo, dale permiso de publicar."
        _fallos=$(( _fallos + 1 ))
    fi
fi

info ""
if [ "$_fallos" -gt 0 ]; then
    err "$_fallos canal(es) no funcionan. Corrige y vuelve a ejecutar."
fi
info "Todo listo. El vigía usará estos canales en su próxima ronda."
info "Para forzar una ahora:  systemctl --user start gh-runner-vigilar.service"
