#!/bin/sh
# ============================================================================
# configurar-avisos.sh — deja listos los avisos del vigía en ESTA máquina.
#
# El vigía (gh_runner: `deploy.sh --vigilar`) detecta runners atascados, caídos
# y el reloj desfasado, pero NO decide cómo te avisa: eso lo hacen los hooks, y
# el hook necesita su credencial. Este script hace ese último tramo sin que
# tengas que editar ficheros a mano en cada host:
#
#   1. Escribe ./vigia/avisos.conf (chmod 600) con tus valores.
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
#   HC_PING_KEY=… sh scripts/configurar-avisos.sh --no-preguntar
#
# Un solo canal también vale: deja el otro en blanco y no se toca.
# ============================================================================
set -eu

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# El directorio del DESPLIEGUE, no ~/.config: es lo que permite que dos clusters
# de la misma máquina tengan avisos separados. Con la ruta compartida de antes,
# ambos pingeaban el MISMO check y el latido sano de uno mantenía el check verde
# aunque el otro estuviese muerto.
HOOKS_DIR="${VIGILAR_HOOKS:-$(pwd)/vigia/hooks.d}"
CONF="${VIGILAR_CONF:-$(pwd)/vigia/avisos.conf}"
# De aquí sale la IDENTIDAD del cluster (ver más abajo, en la prueba del canal).
# No se deduce del nombre del directorio: tiene que ser exactamente la misma que
# usa el vigía, y la única forma de garantizarlo es leerla de donde él la lee.
COMPOSE="${VIGILAR_COMPOSE:-$(pwd)/compose.yaml}"
HC_PING_KEY="${HC_PING_KEY:-}"
HC_API_KEY="${HC_API_KEY:-}"
PREGUNTAR="si"
PROBAR="si"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --hc-url)           HC_URL="${2:?}"; shift 2 ;;
        --hc-ping-key)      HC_PING_KEY="${2:?}"; shift 2 ;;
        --hc-api-key)       HC_API_KEY="${2:?}"; shift 2 ;;
        --hooks)            HOOKS_DIR="${2:?}"; shift 2 ;;
        --conf)             CONF="${2:?}"; shift 2 ;;
        --compose)          COMPOSE="${2:?}"; shift 2 ;;
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
                info '  --hooks RUTA            Dir de hooks del vigía'
                info '  --conf RUTA             Dónde guardar la configuración'
                info '  --compose RUTA          compose.yaml del que sale el nombre del check'
                info '  --no-preguntar          No preguntar lo que falte'
                info '  --no-probar             No mandar la prueba por cada canal'
            fi
            exit 0 ;;
        *) err "opción desconocida: $1 (usa --help)" ;;
    esac
done

HC_URL="${HC_URL:-}"

command -v curl >/dev/null 2>&1 || err "hace falta 'curl'."

# ---- Reusar lo ya configurado ----------------------------------------------
# Sin esto, volver a ejecutar (por ejemplo si el comando de despliegue lo
# encadena) pediría el token OTRA VEZ en cada re-deploy. Precedencia final:
# bandera > entorno > lo que ya había en el fichero > preguntar.
_hc="$HC_URL"
_pk="$HC_PING_KEY"; _ak="$HC_API_KEY"
YA_HABIA="no"
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF" || err "no pude leer $CONF (¿está corrupto?)."
    YA_HABIA="si"
fi
[ -n "$_hc" ] && HC_URL="$_hc"
[ -n "$_pk" ] && HC_PING_KEY="$_pk"
[ -n "$_ak" ] && HC_API_KEY="$_ak"
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
    # La PING KEY es del proyecto, no de un check: la misma sirve para todas las
    # máquinas, y el check de cada cluster se crea solo en su primer ping. Es lo
    # que hace que montar un cluster nuevo no exija tocar el panel.
    if [ -z "$HC_URL" ] && [ -z "$HC_PING_KEY" ]; then
        info "healthchecks.io — Settings del proyecto -> «Ping key»."
        HC_PING_KEY="$(preguntar 'Ping key del proyecto (Enter para usar una URL suelta): ')"
        [ -n "$HC_PING_KEY" ] || HC_URL="$(preguntar 'URL de ping de un check concreto: ')"
    fi
    # Opcional y más potente que la ping key: permite leer y modificar TODOS los
    # checks del proyecto. A cambio, el vigía deja su check con el periodo y el
    # margen correctos; sin ella, el check autocreado nace con periodo de 1 día y
    # hay que ajustarlo a mano una vez.
    if [ -n "$HC_PING_KEY" ] && [ -z "$HC_API_KEY" ]; then
        info ""
        info "Opcional: con una API key el vigía configura su propio check (periodo,"
        info "margen, etiquetas). Sin ella, el check nace con periodo de 1 DÍA y hay"
        info "que ajustarlo a mano en el panel — si no, un host caído tarda un día"
        info "en avisar."
        HC_API_KEY="$(preguntar 'API key del proyecto (Enter para omitir): ')"
    fi
fi

[ -n "$HC_URL$HC_PING_KEY" ] || err "no configuraste ningún canal; no hay nada que hacer."

# ---- Validaciones de forma (baratas, y ahorran un susto) -------------------
if [ -n "$HC_URL" ]; then
    case "$HC_URL" in
        https://*) : ;;
        *) err "la URL de ping debe empezar por https:// (llegó: '$HC_URL')" ;;
    esac
fi

# Se comprueba ANTES de probar los canales: no tiene sentido mandar mensajes de
# prueba para acabar fallando porque el vigía ni siquiera está instalado.
[ -d "$HOOKS_DIR" ] || err "no existe $HOOKS_DIR.
       Corre esto en el DIRECTORIO del despliegue (donde está compose.yaml), y
       genera antes el vigía:  sh deploy.sh … --vigilar   (o pasa --hooks RUTA)"

# ---- Probar ANTES de guardar nada ------------------------------------------
# El orden importa. Guardar primero y probar después dejaría en disco una
# configuración que el propio script acaba de declarar rota, y como al re-
# ejecutarse reusa lo guardado, ese valor malo quedaría pegado: un typo en la URL
# sobreviviría a los siguientes intentos.
#
# Probando primero, un intento fallido no toca nada: si ya tenías una
# configuración que funcionaba, sigue intacta.
_fallos=0
if [ "$PROBAR" = "si" ]; then
    info ""
    info "Probando los canales..."

    if [ -n "$HC_URL" ] || [ -n "$HC_PING_KEY" ]; then
        # Con ping key, el slug identifica a ESTE cluster EN ESTA máquina: el
        # mismo que usará el vigía en cada ronda. Y `?create=1` deja el check ya
        # creado, así que esta prueba hace doble trabajo: valida la clave y da de
        # alta el cluster.
        if [ -n "$HC_URL" ]; then
            _destino="$HC_URL"
        else
            # El slug SALE DEL compose.yaml, no del nombre del directorio. Es la
            # misma identidad que usará el hook en cada ronda (cluster + máquina),
            # y leerla de ahí es lo único que garantiza que no diverjan: cuando se
            # calculaban por separado, un solo despliegue creaba DOS checks —el de
            # esta prueba y el del vigía— y solo uno quedaba bien configurado.
            _cl="$(sed -n 's/^[[:space:]]*VIGIA_CLUSTER:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$COMPOSE" 2>/dev/null | head -n1)"
            _ho="$(sed -n 's/^[[:space:]]*VIGIA_HOST:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$COMPOSE" 2>/dev/null | head -n1)"

            if [ -z "$_cl" ]; then
                err "no encuentro VIGIA_CLUSTER en $COMPOSE.
       Corre esto en el directorio del despliegue, y genera antes el vigía:
           sh deploy.sh … --vigilar
       (o apunta al compose con --compose RUTA)"
            fi
            if [ -z "$_ho" ]; then
                err "tu $COMPOSE no tiene VIGIA_HOST: lo generó una versión anterior.
       Sin él, el vigía usa el ID del contenedor como nombre de máquina, y ese ID
       CAMBIA en cada arranque: tendrías un check nuevo cada vez.
       Vuelve a generar el despliegue:  sh deploy.sh … --vigilar --no-up"
            fi

            _slug="$(printf '%s-%s' "$_cl" "$_ho" \
                     | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-')"
            _destino="https://hc-ping.com/${HC_PING_KEY}/${_slug%-}?create=1"
        fi
        # Ping normal, NUNCA /fail: una prueba no debe dejar el check en rojo ni
        # despertar a nadie. Basta con que healthchecks.io lo registre.
        if curl -fsS -m 15 --retry 2 -X POST -H 'Content-Type: text/plain; charset=utf-8' \
                --data-raw 'Prueba de configurar-avisos.sh: el canal funciona.' \
                "$_destino" >/dev/null 2>&1; then
            info "  healthchecks.io: OK (míralo en el panel del proyecto)."
        else
            info "  healthchecks.io: FALLÓ. Revisa la ping key o la URL."
            _fallos=$(( _fallos + 1 ))
        fi
    fi


    if [ "$_fallos" -gt 0 ]; then
        info ""
        [ "$YA_HABIA" = "si" ] && info "No he tocado $CONF: lo que tenías sigue como estaba."
        err "$_fallos canal(es) no funcionan. Corrige y vuelve a ejecutar."
    fi
fi

# ---- Guardar la configuración ----------------------------------------------
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
    [ -n "$HC_PING_KEY" ] && printf 'HC_PING_KEY=%s\n' "$(entrecomillar "$HC_PING_KEY")"
    [ -n "$HC_API_KEY" ]  && printf 'HC_API_KEY=%s\n' "$(entrecomillar "$HC_API_KEY")"
    [ -n "$HC_URL" ]    && printf 'HC_URL=%s\n' "$(entrecomillar "$HC_URL")"
    :
} > "$CONF"
chmod 600 "$CONF"
info ""
info "Escrito $CONF (chmod 600)."

# El aviso que más importa de todo el script. Sin API key, el check autocreado se
# queda con el periodo por defecto de healthchecks.io —UN DÍA— y con eso una
# máquina apagada tarda un día en avisar: creerías estar vigilado sin estarlo.
if [ -n "$HC_PING_KEY" ] && [ -z "$HC_API_KEY" ]; then
    info ""
    info "⚠  SIN API KEY: el check se crea con PERIODO DE 1 DÍA y margen de 1 hora."
    info "   Con eso, una máquina caída tardaría UN DÍA en avisar."
    info "   Ajústalo A MANO en el panel del check (una vez):"
    info "       Period      = 10 minutes"
    info "       Grace Time  = 5 minutes"
    info "   O vuelve a ejecutar esto con --hc-api-key y lo deja puesto el vigía."
fi

# ---- Activar los hooks -----------------------------------------------------
# Los hooks los instala `deploy.sh --vigilar` con sufijo .ejemplo, para que no
# se ejecuten a medio configurar. Activarlos es quitarles el sufijo.
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
{ [ -n "$HC_URL" ] || [ -n "$HC_PING_KEY" ]; } && activar 10-healthchecks.sh

info ""
if [ "$PROBAR" = "si" ]; then
    info "Todo listo. El vigía usará estos canales en su próxima ronda."
else
    info "Listo (sin probar los canales)."
fi
info "Para forzar una ronda ahora:  podman compose restart vigia"
info "Para ver el informe:           podman compose logs -f vigia"
