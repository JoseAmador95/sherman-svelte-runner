<#
.SYNOPSIS
  configurar-avisos.ps1 — deja listos los avisos del vigía en ESTA máquina, en
  PowerShell nativo. Equivalente de configurar-avisos.sh para Windows.

.DESCRIPTION
  El vigía (gh_runner: `deploy.ps1 -Vigilar`) detecta runners atascados, caídos y
  el reloj desfasado, pero NO decide cómo te avisa: eso lo hacen los hooks, y el
  hook necesita su credencial. Este script hace ese último tramo:

    1. Escribe .\vigia\avisos.conf (solo para tu usuario) con tus valores.
    2. Activa los hooks que correspondan (copia el .ejemplo sin el sufijo).
    3. MANDA UNA PRUEBA por cada canal configurado.

  El paso 3 es el que de verdad importa. Un aviso mal cableado no falla: calla, y
  calla exactamente igual que un fleet sano. Si no lo pruebas al instalarlo, te
  enteras la noche que se cae algo — que es cuando ya no sirve.

  POR QUÉ EXISTE ESTE FICHERO Y NO SE REUSA EL .sh: el README mandaba ejecutar el
  script POSIX con `sh.exe -c "$(...)"`, y en una máquina Windows normal eso falla
  con «sh.exe no existe». Git para Windows solo añade al PATH su carpeta `cmd\`
  (git.exe, gh.exe), no `bin\` — así que `sh.exe` no está ni siquiera teniéndolo
  instalado, y el fleet se quedaba sin avisos justo donde `deploy.ps1` acababa de
  quitar la dependencia de Git Bash para todo lo demás.

  LOS SECRETOS NO VIVEN EN ESTE REPO, y no pueden: es público. Los pones tú al
  ejecutarlo, y se quedan solo en el host.

.EXAMPLE
  # En el directorio del despliegue (donde está compose.yaml):
  .\configurar-avisos.ps1

.EXAMPLE
  # Un comando desde internet (te pregunta lo que falte):
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/JoseAmador95/sherman-svelte-runner/main/scripts/configurar-avisos.ps1)))

.EXAMPLE
  # Desatendido (ojo: el valor queda en el historial de PowerShell):
  .\configurar-avisos.ps1 -HcPingKey PK... -NoPreguntar
#>
[CmdletBinding()]
param(
    [string]$HcUrl,
    [string]$HcPingKey,
    [string]$HcApiKey,
    [string]$Hooks,
    [string]$Conf,
    [string]$Compose,
    [switch]$NoPreguntar,
    [switch]$NoProbar,
    [switch]$Help
)

# 'Continue' y no 'Stop', por el mismo motivo que deploy.ps1: los comandos
# nativos (icacls, chmod) escriben a stderr y bajo 'Stop' Windows PowerShell los
# convierte en error TERMINANTE. Lo que sí importa lleva -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

# TLS 1.2 explícito: Windows PowerShell 5.1 negocia TLS 1.0 por defecto y
# hc-ping.com lo rechaza. Sin esto, la prueba fallaría con un error de red que no
# dice nada del verdadero motivo.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }

function Die($m)  { [Console]::Error.WriteLine("ERROR: $m"); exit 1 }
function Info($m) { [Console]::Error.WriteLine($m) }
function Hay($n)  { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

if ($Help) {
    Info @'
Uso: configurar-avisos.ps1 [parámetros]

  -HcUrl URL         Ping de healthchecks.io de un check concreto (env: HC_URL)
  -HcPingKey CLAVE   Ping key del PROYECTO (env: HC_PING_KEY)
  -HcApiKey CLAVE    API key del proyecto; deja el check bien configurado
                     (env: HC_API_KEY)
  -Hooks RUTA        Dir de hooks del vigía (por defecto .\vigia\hooks.d)
  -Conf RUTA         Dónde guardar la configuración (.\vigia\avisos.conf)
  -Compose RUTA      compose.yaml del que sale el nombre del check
  -NoPreguntar       No preguntar lo que falte
  -NoProbar          No mandar la prueba por cada canal
'@
    exit 0
}

# ---- Rutas: el DESPLIEGUE, no %APPDATA% ------------------------------------
# Es lo que permite que dos clusters de la misma máquina tengan avisos separados.
# Con una ruta compartida, ambos pingearían el MISMO check y el latido sano de uno
# mantendría el check verde aunque el otro estuviese muerto.
$dir = (Get-Location).ProviderPath
if (-not $Hooks)   { $Hooks   = if ($env:VIGILAR_HOOKS)   { $env:VIGILAR_HOOKS }   else { Join-Path (Join-Path $dir 'vigia') 'hooks.d' } }
if (-not $Conf)    { $Conf    = if ($env:VIGILAR_CONF)    { $env:VIGILAR_CONF }    else { Join-Path (Join-Path $dir 'vigia') 'avisos.conf' } }
# De aquí sale la IDENTIDAD del cluster (ver más abajo, en la prueba del canal).
# No se deduce del nombre del directorio: tiene que ser exactamente la misma que
# usa el vigía, y la única forma de garantizarlo es leerla de donde él la lee.
if (-not $Compose) { $Compose = if ($env:VIGILAR_COMPOSE) { $env:VIGILAR_COMPOSE } else { Join-Path $dir 'compose.yaml' } }

if (-not $HcUrl)     { $HcUrl     = $env:HC_URL }
if (-not $HcPingKey) { $HcPingKey = $env:HC_PING_KEY }
if (-not $HcApiKey)  { $HcApiKey  = $env:HC_API_KEY }

# ---- Reusar lo ya configurado ----------------------------------------------
# Sin esto, volver a ejecutar (por ejemplo si el comando de despliegue lo
# encadena) pediría el token OTRA VEZ en cada re-deploy. Precedencia final:
# parámetro > entorno > lo que ya había en el fichero > preguntar.
function Leer-Conf($ruta) {
    $r = @{}
    if (-not (Test-Path -LiteralPath $ruta)) { return $r }
    foreach ($linea in (Get-Content -LiteralPath $ruta -ErrorAction Stop)) {
        if ($linea -match "^\s*#") { continue }
        if ($linea -match "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'(.*)'\s*$") {
            # El fichero lo escribe este script en formato shell (lo lee el hook
            # con `.`), así que hay que deshacer el escape de la comilla simple.
            $r[$Matches[1]] = $Matches[2].Replace("'\''", "'")
        }
        elseif ($linea -match "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$") {
            $r[$Matches[1]] = $Matches[2]
        }
    }
    return $r
}

$previo = Leer-Conf $Conf
$yaHabia = $previo.Count -gt 0
if (-not $HcUrl)     { $HcUrl     = [string]$previo['HC_URL'] }
if (-not $HcPingKey) { $HcPingKey = [string]$previo['HC_PING_KEY'] }
if (-not $HcApiKey)  { $HcApiKey  = [string]$previo['HC_API_KEY'] }
if ($yaHabia) { Info "Reusando lo que ya había en $Conf (un parámetro o variable de entorno lo sustituye)." }

# Base de ping: la del servicio público salvo que uses una instancia propia
# (healthchecks.io es self-hostable). El hook lee esta misma variable de
# avisos.conf, así que la prueba tiene que respetarla o probaría otro servidor.
$hcBase = if ($env:HC_BASE) { $env:HC_BASE } elseif ($previo['HC_BASE']) { [string]$previo['HC_BASE'] } else { 'https://hc-ping.com' }

# ---- Preguntar lo que falte ------------------------------------------------
# Igual que deploy.ps1 con el PAT: preguntar es el camino por defecto, para que el
# secreto no acabe en el historial de PowerShell.
$interactivo = -not [Console]::IsInputRedirected
if (-not $NoPreguntar -and $interactivo) {
    Info "Deja en blanco cualquier canal que no quieras configurar."
    Info ""
    # La PING KEY es del proyecto, no de un check: la misma sirve para todas las
    # máquinas, y el check de cada cluster se crea solo en su primer ping. Es lo
    # que hace que montar un cluster nuevo no exija tocar el panel.
    if (-not $HcUrl -and -not $HcPingKey) {
        Info "healthchecks.io — Settings del proyecto -> «Ping key»."
        $HcPingKey = (Read-Host 'Ping key del proyecto (Enter para usar una URL suelta)').Trim()
        if (-not $HcPingKey) { $HcUrl = (Read-Host 'URL de ping de un check concreto').Trim() }
    }
    # Opcional y más potente que la ping key: permite leer y modificar TODOS los
    # checks del proyecto. A cambio, el vigía deja su check con el periodo y el
    # margen correctos; sin ella, el check autocreado nace con periodo de 1 día y
    # hay que ajustarlo a mano una vez.
    if ($HcPingKey -and -not $HcApiKey) {
        Info ""
        Info "Opcional: con una API key el vigía configura su propio check (periodo,"
        Info "margen, etiquetas). Sin ella, el check nace con periodo de 1 DÍA y hay"
        Info "que ajustarlo a mano en el panel — si no, un host caído tarda un día"
        Info "en avisar."
        $HcApiKey = (Read-Host 'API key del proyecto (Enter para omitir)').Trim()
    }
}

if (-not $HcUrl -and -not $HcPingKey) { Die "no configuraste ningún canal; no hay nada que hacer." }

# ---- Validaciones de forma (baratas, y ahorran un susto) -------------------
if ($HcUrl -and $HcUrl -notmatch '^https://') {
    Die "la URL de ping debe empezar por https:// (llegó: '$HcUrl')"
}

# Se comprueba ANTES de probar los canales: no tiene sentido mandar mensajes de
# prueba para acabar fallando porque el vigía ni siquiera está instalado.
if (-not (Test-Path -LiteralPath $Hooks)) {
    Die "no existe $Hooks.
       Corre esto en el DIRECTORIO del despliegue (donde está compose.yaml), y
       genera antes el vigía:  .\deploy.ps1 … -Vigilar   (o pasa -Hooks RUTA)"
}

function Leer-VarCompose($ruta, $clave) {
    foreach ($linea in (Get-Content -LiteralPath $ruta -ErrorAction Stop)) {
        if ($linea -match ('^\s*' + [regex]::Escape($clave) + ':\s*"?([^"]*?)"?\s*$')) { return $Matches[1] }
    }
    return ''
}

# ---- Probar ANTES de guardar nada ------------------------------------------
# El orden importa. Guardar primero y probar después dejaría en disco una
# configuración que el propio script acaba de declarar rota, y como al
# re-ejecutarse reusa lo guardado, ese valor malo quedaría pegado: un typo en la
# URL sobreviviría a los siguientes intentos.
#
# Probando primero, un intento fallido no toca nada: si ya tenías una
# configuración que funcionaba, sigue intacta.
function Probar-Canal($url) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -TimeoutSec 15 `
                -ContentType 'text/plain; charset=utf-8' `
                -Body 'Prueba de configurar-avisos.ps1: el canal funciona.' `
                -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            if ($i -eq 3) { return $false }
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

$fallos = 0
if (-not $NoProbar) {
    Info ""
    Info "Probando los canales..."

    if ($HcUrl) {
        $destino = $HcUrl
    }
    else {
        # El slug SALE DEL compose.yaml, no del nombre del directorio. Es la misma
        # identidad que usará el hook en cada ronda (cluster + máquina), y leerla
        # de ahí es lo único que garantiza que no diverjan: cuando se calculaban
        # por separado, un solo despliegue creaba DOS checks —el de esta prueba y
        # el del vigía— y solo uno quedaba bien configurado.
        if (-not (Test-Path -LiteralPath $Compose)) {
            Die "no encuentro $Compose.
       Corre esto en el directorio del despliegue, y genera antes el vigía:
           .\deploy.ps1 … -Vigilar
       (o apunta al compose con -Compose RUTA)"
        }
        $cl = Leer-VarCompose $Compose 'VIGIA_CLUSTER'
        $ho = Leer-VarCompose $Compose 'VIGIA_HOST'
        if (-not $cl) {
            Die "no encuentro VIGIA_CLUSTER en $Compose.
       Corre esto en el directorio del despliegue, y genera antes el vigía:
           .\deploy.ps1 … -Vigilar"
        }
        if (-not $ho) {
            Die "tu $Compose no tiene VIGIA_HOST: lo generó una versión anterior.
       Sin él, el vigía usa el ID del contenedor como nombre de máquina, y ese ID
       CAMBIA en cada arranque: tendrías un check nuevo cada vez.
       Vuelve a generar el despliegue:  .\deploy.ps1 … -Vigilar -NoUp"
        }
        # Mismo saneado que el hook (gh_runner: hooks/10-healthchecks.sh.ejemplo):
        # minúsculas, todo lo que no sea [a-z0-9-] a guion, guiones colapsados.
        $slug = ("$cl-$ho").ToLowerInvariant()
        $slug = ($slug -replace '[^a-z0-9-]', '-') -replace '-+', '-'
        $slug = $slug.TrimEnd('-')
        # `?create=1` deja el check ya creado, así que esta prueba hace doble
        # trabajo: valida la clave y da de alta el cluster.
        $destino = "$($hcBase.TrimEnd('/'))/$HcPingKey/$slug" + '?create=1'
    }

    # Ping normal, NUNCA /fail: una prueba no debe dejar el check en rojo ni
    # despertar a nadie. Basta con que healthchecks.io lo registre.
    if (Probar-Canal $destino) {
        Info "  healthchecks.io: OK (míralo en el panel del proyecto)."
    }
    else {
        Info "  healthchecks.io: FALLÓ. Revisa la ping key o la URL."
        $fallos++
    }

    if ($fallos -gt 0) {
        Info ""
        if ($yaHabia) { Info "No he tocado ${Conf}: lo que tenías sigue como estaba." }
        Die "$fallos canal(es) no funcionan. Corrige y vuelve a ejecutar."
    }
}

# ---- Guardar la configuración ----------------------------------------------
# Entre comillas simples y escapando las que traiga el valor: los hooks hacen `.`
# sobre este fichero DENTRO del contenedor (es Linux), así que un valor sin
# escapar sería ejecutable.
function Entrecomillar($v) { "'" + ([string]$v).Replace("'", "'\''") + "'" }

$texto = "# GENERADO por configurar-avisos.ps1 — valores de los hooks del vigía.`n"
$texto += "# Contiene credenciales: acceso restringido y NUNCA se commitea.`n"
if ($HcPingKey) { $texto += "HC_PING_KEY=$(Entrecomillar $HcPingKey)`n" }
if ($HcApiKey)  { $texto += "HC_API_KEY=$(Entrecomillar $HcApiKey)`n" }
if ($HcUrl)     { $texto += "HC_URL=$(Entrecomillar $HcUrl)`n" }

$confDir = Split-Path -Parent $Conf
if ($confDir -and -not (Test-Path -LiteralPath $confDir)) { New-Item -ItemType Directory -Force -Path $confDir | Out-Null }
# UTF-8 SIN BOM y saltos LF, sí o sí: este fichero lo lee `.` de /bin/sh dentro
# del contenedor. Con CRLF, el valor acabaría con un \r pegado y la URL de ping
# no existiría; con BOM, la primera línea ni siquiera sería un comentario válido.
# Sin operador ternario: Windows PowerShell 5.1 no lo tiene y el script debe
# correr ahí (solo el `&&` del README pide PowerShell 7).
$confFull = if ([System.IO.Path]::IsPathRooted($Conf)) { $Conf } else { Join-Path $dir $Conf }
[System.IO.File]::WriteAllText($confFull, $texto, (New-Object System.Text.UTF8Encoding($false)))

# Permisos: el equivalente del chmod 600 del script POSIX. En NTFS es best-effort
# (Windows usa ACLs), igual que hace deploy.ps1 con .env y el access_token.
if (Hay 'icacls') {
    $full = (Resolve-Path -LiteralPath $Conf).ProviderPath
    & icacls $full /inheritance:r /grant:r "$($env:USERNAME):(F)" *> $null
    if ($LASTEXITCODE -ne 0) { Info "AVISO: no pude restringir los permisos de $Conf (icacls). Protégelo a mano si el host es compartido." }
}
elseif (Hay 'chmod') { & chmod 600 $Conf }
Info ""
Info "Escrito $Conf."

# El aviso que más importa de todo el script. Sin API key, el check autocreado se
# queda con el periodo por defecto de healthchecks.io —UN DÍA— y con eso una
# máquina apagada tarda un día en avisar: creerías estar vigilado sin estarlo.
if ($HcPingKey -and -not $HcApiKey) {
    Info ""
    Info "!  SIN API KEY: el check se crea con PERIODO DE 1 DÍA y margen de 1 hora."
    Info "   Con eso, una máquina caída tardaría UN DÍA en avisar."
    Info "   Ajústalo A MANO en el panel del check (una vez):"
    Info "       Period      = 10 minutes"
    Info "       Grace Time  = 5 minutes"
    Info "   O vuelve a ejecutar esto con -HcApiKey y lo deja puesto el vigía."
}

# ---- Activar los hooks -----------------------------------------------------
# Los hooks los instala `deploy.ps1 -Vigilar` con sufijo .ejemplo, para que no se
# ejecuten a medio configurar. Activarlos es quitarles el sufijo.
function Activar($nombre) {
    $act = Join-Path $Hooks $nombre
    if (Test-Path -LiteralPath $act) {
        # NO se toca el CONTENIDO —puede llevar ajustes—, pero el bit de ejecución
        # sí se garantiza donde exista el concepto: `vigilar.sh` solo ejecuta lo que
        # pasa `[ -x ]`, así que un hook sin ese bit es igual que no tenerlo.
        if (Hay 'chmod') { & chmod 700 $act }
        Info "  $nombre ya estaba activo (no lo toco: puede que lo hayas ajustado)."
        return
    }
    if (-not (Test-Path -LiteralPath "$act.ejemplo")) {
        Info "  AVISO: no encuentro $act.ejemplo; sáltate este canal."
        return
    }
    Copy-Item -LiteralPath "$act.ejemplo" -Destination $act -Force
    if (Hay 'chmod') { & chmod 700 $act }
    Info "  $nombre activado."
}

Info "Hooks en ${Hooks}:"
Activar '10-healthchecks.sh'

Info ""
# En Windows el bit de ejecución no existe, y si el bind mount no lo simula el
# vigía ignora el hook EN SILENCIO: dice «Hooks ignorados» en su informe y todo lo
# demás sigue verde. Por eso se dice aquí, no solo en el README.
Info "En Windows el permiso de ejecución puede no sobrevivir al bind mount. Si el"
Info "informe del vigía dice «Hooks ignorados», corre:"
Info "    podman compose exec vigia chmod +x /etc/gh-runner/vigia/hooks.d/*.sh"
Info ""
if (-not $NoProbar) { Info "Todo listo. El vigía usará estos canales en su próxima ronda." }
else { Info "Listo (sin probar los canales)." }
Info "Para forzar una ronda ahora:  podman compose restart vigia"
Info "Para ver el informe:           podman compose logs -f vigia"
