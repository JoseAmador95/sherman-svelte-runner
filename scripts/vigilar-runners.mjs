/**
 * Vigía del fleet: revisa los runners self-hosted de un repo y avisa por Telegram cuando cambia
 * el estado (alguno se cae, o vuelven todos).
 *
 * Por qué vive aquí y no en el repo de la app: `sherman-svelte-runner` es **público**, y en repos
 * públicos los minutos de los runners estándar de GitHub son gratis. Un cron horario cuesta cero.
 * El repo de la app es privado, así que ahí el mismo cron se facturaría.
 *
 * Es el ÚNICO aviso de fleet caído: la CI de la app apunta al fleet con `runs-on` fijo, sin
 * respaldo en runners de pago, así que un fleet que no responde deja sus jobs EN COLA en vez de
 * mandarlos a `ubuntu-latest`. No hay factura ni corrida roja que lo delate. Y al ir por reloj y no
 * por corrida, cubre los huecos sin actividad (noches y fines de semana, cuando nadie empuja código
 * y la CI no corre), que es cuando el fleet se cae sin que nadie mire.
 *
 * ANTI-SPAM: solo habla cuando el conjunto de runners caídos CAMBIA respecto a la ronda anterior
 * (incluido el «ya volvieron todos»). El estado previo se pasa por `--estado-previo=<ruta>` y se
 * escribe en `--estado=<ruta>`; el workflow los persiste con `actions/cache`. Sin estado previo se
 * trata como primera ronda: avisa solo si hay algo caído.
 *
 * POR PLATAFORMA: `RUNNERS_ESPERADOS_POR` («linux=12,macos=2!,escritorio=1») reparte lo esperado
 * entre grupos, porque con un contador plano un Mac caído se diluye en la cuenta global. El sufijo
 * `!` marca el grupo como efímero (VMs de Tart que rotan entre jobs) y su déficit se confirma en
 * dos rondas: ver `evaluarGrupos`. Sin la variable, todo se comporta exactamente como antes.
 *
 * Uso local (no envía nada):
 *   SHERMAN_PAT=github_pat_… node scripts/vigilar-runners.mjs --repo=demeneghi/sherman-svelte --dry-run
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const ETIQUETA_POR_DEFECTO = 'sherman';
const TIEMPO_MAX_API_MS = 15_000;
const MAX_NOMBRES_EN_MENSAJE = 12;

function leerBandera(nombre, porDefecto = null) {
	const prefijo = `--${nombre}=`;
	const arg = process.argv.find((a) => a.startsWith(prefijo));
	return arg ? arg.slice(prefijo.length) : porDefecto;
}

/** Telegram interpreta HTML, así que el texto de datos hay que escaparlo. */
export function escaparHtml(texto) {
	return String(texto ?? '')
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;');
}

/**
 * Reduce el inventario del repo al estado que interesa vigilar.
 *
 * La comparación de etiquetas es insensible a mayúsculas: GitHub añade las suyas capitalizadas
 * (`Linux`, `X64`) y las trata así en `runs-on`.
 */
export function estadoFleet(runners, etiqueta) {
	const objetivo = String(etiqueta).toLowerCase();
	const delFleet = (runners ?? []).filter((r) =>
		(r?.labels ?? []).some((l) => String(l?.name ?? '').toLowerCase() === objetivo)
	);
	const caidos = delFleet
		.filter((r) => r?.status !== 'online')
		.map((r) => r?.name ?? '(sin nombre)')
		.sort();
	return {
		total: delFleet.length,
		online: delFleet.filter((r) => r?.status === 'online').length,
		ocupados: delFleet.filter((r) => r?.status === 'online' && r?.busy).length,
		caidos
	};
}

/**
 * Reparte el fleet por plataforma. La clave de cada grupo es una etiqueta que debe estar ADEMÁS de
 * `etiqueta` (AND), y su valor configurado es cuántos se esperan ahí.
 *
 * El truco que evita re-desplegar los 12 runners que ya corren: `linux` y `macos` son etiquetas que
 * **GitHub añade solo** al registrar el runner (`Linux`, `macOS`), y la comparación va en minúsculas
 * como en `estadoFleet`. Solo `escritorio` es etiqueta nuestra, y solo la lleva el runner nuevo.
 *
 * `estadoFleet` se deja intacta a propósito: es la que decide el aviso global y ya está probada.
 */
export function estadoPorGrupo(runners, etiqueta, grupos) {
	const objetivo = String(etiqueta).toLowerCase();
	const nombres = Array.isArray(grupos) ? grupos : Object.keys(grupos ?? {});
	const salida = {};
	for (const nombre of nombres) {
		const marca = String(nombre).toLowerCase();
		const delGrupo = (runners ?? []).filter((r) => {
			const etiquetas = (r?.labels ?? []).map((l) => String(l?.name ?? '').toLowerCase());
			return etiquetas.includes(objetivo) && etiquetas.includes(marca);
		});
		salida[nombre] = {
			total: delGrupo.length,
			online: delGrupo.filter((r) => r?.status === 'online').length,
			ocupados: delGrupo.filter((r) => r?.status === 'online' && r?.busy).length,
			caidos: delGrupo
				.filter((r) => r?.status !== 'online')
				.map((r) => r?.name ?? '(sin nombre)')
				.sort()
		};
	}
	return salida;
}

/**
 * Lee `RUNNERS_ESPERADOS_POR`: «linux=12,macos=2!,escritorio=1».
 *
 * El sufijo `!` marca el grupo como EFÍMERO (sus runners se destruyen y se vuelven a crear entre
 * job y job). Devuelve `null` si no hay nada configurado, y ese `null` es el que conserva el
 * comportamiento anterior byte a byte: sin grupos, ni la huella ni el mensaje cambian.
 */
export function parsearGrupos(cadena) {
	const texto = String(cadena ?? '').trim();
	if (!texto) return null;
	const grupos = {};
	for (const parte of texto.split(',')) {
		const entrada = parte.trim();
		if (!entrada) continue;
		const sep = entrada.indexOf('=');
		const nombre = (sep >= 0 ? entrada.slice(0, sep) : entrada).trim().toLowerCase();
		let valor = (sep >= 0 ? entrada.slice(sep + 1) : '').trim();
		const efimero = valor.endsWith('!');
		if (efimero) valor = valor.slice(0, -1).trim();
		if (!nombre) continue;
		grupos[nombre] = { esperados: Number(valor) || 0, efimero };
	}
	return Object.keys(grupos).length > 0 ? grupos : null;
}

/**
 * Contrasta lo esperado por grupo con lo que hay, aplicando la CONFIRMACIÓN EN DOS RONDAS de los
 * grupos efímeros.
 *
 * Por qué esa espera: entre job y job un slot de macOS rota — la VM de Tart se destruye y se crea
 * otra, y durante 60-90 s no hay ningún runner registrado. Con el cron horario eso es ~2,5 % de
 * probabilidad por slot de muestrear justo el hueco, o sea un falso «Falta un runner» cada pocas
 * semanas por slot. Un déficit en un grupo marcado con `!` solo se anuncia si aparece en DOS rondas
 * seguidas (`pendiente` viaja en el estado persistido).
 *
 * Las 2 h de latencia que eso mete para una caída REAL de macOS son aceptables porque el camino
 * rápido lo cubre otra capa: el vigía del host (`vigilar.sh` de gh_runner, ronda de 5 min) mira el
 * SLOT —el proceso y la VM en la máquina—, no el registro en GitHub, así que un Mac apagado de
 * verdad se detecta ahí en minutos. Este vigía es la red de seguridad, no el primer aviso.
 *
 * Mientras el hueco no está confirmado se cuenta como PRESENTE (`huecoNoConfirmado`), o el fleet se
 * declararía enfermo por una rotación. Y `totalEfimeros` es lo que la huella descuenta del total
 * (ver `decidirAviso`): sin eso, el vaivén normal de las VMs movería la huella en cada rotación y el
 * anti-spam hablaría igual, que es justo lo que esta espera existe para evitar.
 */
export function evaluarGrupos({ grupos, porGrupo, previo }) {
	if (!grupos) {
		return { faltanPorGrupo: {}, pendiente: [], huecoNoConfirmado: 0, totalEfimeros: 0 };
	}
	const pendientePrevio = new Set(Array.isArray(previo?.pendiente) ? previo.pendiente : []);
	const faltanPorGrupo = {};
	const pendiente = [];
	let huecoNoConfirmado = 0;
	let totalEfimeros = 0;

	for (const [nombre, conf] of Object.entries(grupos)) {
		const esperados = Number(conf?.esperados) || 0;
		if (esperados <= 0) continue;
		const hay = porGrupo?.[nombre]?.total ?? 0;
		if (conf?.efimero) totalEfimeros += hay;
		const faltan = Math.max(0, esperados - hay);
		if (faltan === 0) continue;
		if (conf?.efimero) {
			pendiente.push(nombre);
			if (!pendientePrevio.has(nombre)) {
				huecoNoConfirmado += faltan;
				continue;
			}
		}
		faltanPorGrupo[nombre] = faltan;
	}
	pendiente.sort();
	return { faltanPorGrupo, pendiente, huecoNoConfirmado, totalEfimeros };
}

/** Nombres tal y como se escriben en el mensaje; el resto del mundo los ve en minúsculas. */
const NOMBRE_GRUPO = { linux: 'Linux', macos: 'macOS', escritorio: 'Escritorio' };

/**
 * «Linux 12/12 · macOS 2/2 · Escritorio 1/1». Cadena vacía sin grupos configurados: así el mensaje
 * de siempre no gana una línea en blanco.
 */
export function lineaDesglose(porGrupo, grupos) {
	if (!grupos) return '';
	const trozos = [];
	for (const [nombre, conf] of Object.entries(grupos)) {
		const esperados = Number(conf?.esperados) || 0;
		const online = porGrupo?.[nombre]?.online ?? 0;
		const etiqueta = NOMBRE_GRUPO[nombre] ?? nombre;
		trozos.push(`${escaparHtml(etiqueta)} <code>${online}/${esperados}</code>`);
	}
	return trozos.join(' · ');
}

/**
 * Decide si toca hablar.
 *
 * `sano` compara contra lo ESPERADO, no contra lo registrado: un runner que desaparece del listado
 * (el contenedor murió del todo y se desregistró) es tan preocupante como uno `offline`, y mirando
 * solo `caidos` pasaría inadvertido.
 */
export function decidirAviso({
	estado,
	esperados,
	previo,
	forzar = false,
	grupos = null,
	porGrupo = null
}) {
	const { faltanPorGrupo, pendiente, huecoNoConfirmado, totalEfimeros } = evaluarGrupos({
		grupos,
		porGrupo,
		previo
	});
	// El hueco de una rotación aún sin confirmar se cuenta como si el runner estuviera: ver
	// `evaluarGrupos`. Sin esto, bajar el `total` ya delataría la rotación en la primera ronda.
	const totalEfectivo = estado.total + huecoNoConfirmado;
	const faltan = esperados > 0 ? Math.max(0, esperados - totalEfectivo) : 0;
	const faltanPorGrupoTotal = Object.values(faltanPorGrupo).reduce((a, b) => a + b, 0);
	const sano =
		estado.caidos.length === 0 && faltan === 0 && faltanPorGrupoTotal === 0 && estado.online > 0;

	// La huella lleva el déficit POR GRUPO, y no solo el total, porque con dos plataformas el
	// contador plano silencia caídas reales: un Mac que se cae mientras vuelve un Linux deja
	// `caidos` y `total` idénticos, y el aviso no sonaría nunca. El precio, que hay que aceptar y
	// no es un fallo: la primera ronda tras desplegar este cambio ve una huella distinta a la
	// guardada por la versión anterior, así que manda UN mensaje de más y luego se calla.
	//
	// Sin grupos configurados la clave ni siquiera se añade, así que la huella es byte a byte la de
	// antes y las cachés existentes siguen valiendo.
	// Y el `total` de la huella DESCUENTA los runners de los grupos efímeros: su alta y baja continua
	// es el funcionamiento normal, no una novedad, así que contarlos ahí movería la huella en cada
	// rotación y hablaría igual aunque el déficit siguiera sin confirmar. Lo que de verdad falta en
	// esos grupos lo dice `faltanPorGrupo`, y solo cuando ya está confirmado.
	const huella = JSON.stringify(
		grupos
			? { caidos: estado.caidos, total: estado.total - totalEfimeros, faltanPorGrupo }
			: { caidos: estado.caidos, total: estado.total }
	);
	const primeraRonda = previo == null;
	const comun = { sano, huella, faltan, faltanPorGrupo, pendiente };

	// `forzar` salta TODO el anti-spam, y esa es justo su razón de ser: sin él, lanzar el vigía a
	// mano para comprobar que los secretos funcionan devuelve un job verde y silencio, que es
	// indistinguible de tenerlos mal puestos. Solo cambia si se HABLA; el estado se registra igual,
	// así que una comprobación manual no descoloca el anti-spam de la siguiente ronda.
	if (forzar) return { avisar: true, ...comun };

	if (!primeraRonda && previo.huella === huella) return { avisar: false, ...comun };
	// Primera ronda con todo bien: no se anuncia un «va todo bien» que nadie pidió.
	if (sano && primeraRonda) return { avisar: false, ...comun };
	// Recuperación: solo se anuncia si la ronda anterior estaba mal.
	if (sano && previo?.sano !== false) return { avisar: false, ...comun };
	return { avisar: true, ...comun };
}

export function construirMensaje({
	repo,
	estado,
	esperados,
	faltan,
	sano,
	forzado = false,
	grupos = null,
	porGrupo = null,
	faltanPorGrupo = {}
}) {
	// Cadena vacía sin grupos configurados, y entonces nada de esto se añade: el mensaje sale
	// idéntico al de siempre.
	const desglose = lineaDesglose(porGrupo, grupos);
	if (sano) {
		// Con el fleet sano hay dos motivos para hablar, y NO dicen lo mismo: una recuperación
		// («volvieron») o una comprobación que alguien pidió a mano. Anunciar «Runners de vuelta»
		// cuando nunca se cayó nada haría dudar de si hubo una caída que no se vio.
		const cabecera = [
			forzado ? '🔎 <b>Comprobación del vigía</b>' : '✅ <b>Runners de vuelta</b>',
			'',
			`<b>${escaparHtml(repo)}</b> — los <code>${estado.total}</code> runners están en línea.`
		];
		if (desglose) cabecera.push(desglose);
		if (forzado) {
			cabecera.push('', 'Lo pediste a mano; si lees esto, el aviso por Telegram funciona.');
		}
		return cabecera.join('\n');
	}

	const lineas = [
		estado.online === 0 ? '🔴 <b>Fleet caído</b>' : '⚠️ <b>Falta un runner</b>',
		'',
		`<b>${escaparHtml(repo)}</b> — <code>${estado.online}</code> en línea` +
			(esperados > 0 ? ` de <code>${esperados}</code> esperados` : '') +
			`, <code>${estado.ocupados}</code> ${estado.ocupados === 1 ? 'ocupado' : 'ocupados'}.`
	];
	if (desglose) lineas.push(desglose);

	if (estado.caidos.length > 0) {
		lineas.push('');
		lineas.push('Fuera de línea:');
		for (const nombre of estado.caidos.slice(0, MAX_NOMBRES_EN_MENSAJE)) {
			lineas.push(`· <code>${escaparHtml(nombre)}</code>`);
		}
		const resto = estado.caidos.length - MAX_NOMBRES_EN_MENSAJE;
		if (resto > 0) lineas.push(`· …y ${resto} más`);
	}
	const cortos = Object.entries(faltanPorGrupo ?? {});
	if (cortos.length > 0) {
		lineas.push('');
		lineas.push(
			'Sin registrar por plataforma: ' +
				cortos
					.map(([g, n]) => `<code>${n}</code> en ${escaparHtml(NOMBRE_GRUPO[g] ?? g)}`)
					.join(', ') +
				'.'
		);
	}
	if (faltan > 0) {
		lineas.push('');
		lineas.push(
			`Además faltan <code>${faltan}</code> sin registrar: su contenedor pudo morir del todo.`
		);
	}

	lineas.push('');
	lineas.push(
		estado.online === 0
			? 'La CI NO se irá a runners de pago: sus jobs se quedan en cola hasta que vuelvan (GitHub los descarta a las 24 h). Enciende las computadoras del fleet.'
			: 'La CI sigue corriendo con los que quedan, más lenta. Revisa esa computadora.'
	);
	return lineas.join('\n');
}

/** Exportada para que `estado-runners.mjs` no duplique la llamada ni el manejo de errores. */
export async function consultarRunners(repo, token) {
	const res = await fetch(`https://api.github.com/repos/${repo}/actions/runners?per_page=100`, {
		headers: {
			Accept: 'application/vnd.github+json',
			Authorization: `Bearer ${token}`,
			'X-GitHub-Api-Version': '2022-11-28'
		},
		signal: AbortSignal.timeout(TIEMPO_MAX_API_MS)
	});
	if (!res.ok) throw new Error(`la API de GitHub respondió HTTP ${res.status}`);
	return (await res.json())?.runners ?? [];
}

/**
 * Resuelve los destinos del aviso. `TELEGRAM_CHAT_ID` admite una lista separada por comas, así que
 * el mismo mensaje llega a varias personas sin montar un grupo.
 *
 * Formato de cada entrada: **`id`** o **`id:hilo`** (el sufijo es para grupos con temas; un chat
 * normal no los tiene y Telegram rechaza el envío si le mandas un `message_thread_id` inexistente,
 * por eso el tema se declara por destino). `TELEGRAM_THREAD_ID` se conserva y se aplica **solo con
 * un único destino**: con varios no hay forma de saber a cuál pertenece ese tema.
 *
 * Mismo contrato que `scripts/telegram.mjs` del repo de la app; se duplica a propósito porque este
 * repo no comparte código con aquel.
 *
 * @returns {{ chatId: string, hilo: string | null }[]}
 */
export function parsearDestinosTelegram(chatIdRaw, hiloGlobal = null) {
	const destinos = String(chatIdRaw ?? '')
		.split(',')
		.map((entrada) => entrada.trim())
		.filter(Boolean)
		.map((entrada) => {
			// `lastIndexOf` y no `split(':')`: los ids de grupo son negativos pero nunca llevan `:`,
			// y así un `@canal_publico` sin tema tampoco se parte por error.
			const sep = entrada.lastIndexOf(':');
			const hilo = sep > 0 ? entrada.slice(sep + 1).trim() : '';
			if (/^\d+$/.test(hilo)) {
				return { chatId: entrada.slice(0, sep).trim(), hilo };
			}
			return { chatId: entrada, hilo: null };
		})
		.filter((destino) => destino.chatId.length > 0);

	const global = String(hiloGlobal ?? '').trim();
	if (global && destinos.length === 1 && !destinos[0].hilo) {
		destinos[0].hilo = global;
	}
	return destinos;
}

/** Un envío. Devuelve `true` solo si Telegram lo aceptó; nunca lanza. */
async function enviarAChat(token, destino, texto) {
	try {
		const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				chat_id: destino.chatId,
				text: texto,
				parse_mode: 'HTML',
				disable_web_page_preview: true,
				...(destino.hilo ? { message_thread_id: Number(destino.hilo) } : {})
			})
		});
		const json = await res.json().catch(() => null);
		if (!json?.ok) {
			console.error(
				`⚠️  Telegram rechazó el mensaje para ${destino.chatId}:`,
				json?.description ?? res.status
			);
			return false;
		}
		return true;
	} catch (error) {
		console.error(`⚠️  No se pudo contactar con Telegram para ${destino.chatId}:`, error.message);
		return false;
	}
}

async function enviarTelegram(texto) {
	const token = process.env.TELEGRAM_BOT_TOKEN?.trim();
	const hiloGlobal = process.env.TELEGRAM_THREAD_ID?.trim();
	const destinos = parsearDestinosTelegram(process.env.TELEGRAM_CHAT_ID, hiloGlobal);

	if (!token || destinos.length === 0) {
		console.warn('⚠️  Sin TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID: no se envía el mensaje.');
		return;
	}
	if (hiloGlobal && destinos.length > 1) {
		console.warn(
			'⚠️  TELEGRAM_THREAD_ID se ignora con varios destinos: declara el tema en el propio id («-1001234:12»).'
		);
	}

	// En serie y no en paralelo: son dos o tres destinos, y así el log dice cuál falló sin mezclar.
	let entregados = 0;
	for (const destino of destinos) {
		if (await enviarAChat(token, destino, texto)) entregados++;
	}

	if (entregados === 0) return;
	console.log(
		destinos.length === 1
			? '📨 Aviso enviado a Telegram.'
			: `📨 Aviso enviado a Telegram (${entregados}/${destinos.length} destinos).`
	);
}

/** Estado previo ausente o corrupto = primera ronda; nunca revienta por eso. */
function leerEstadoPrevio(ruta) {
	if (!ruta) return null;
	try {
		const previo = JSON.parse(readFileSync(ruta, 'utf8'));
		return typeof previo?.huella === 'string' ? previo : null;
	} catch {
		return null;
	}
}

async function main() {
	const soloPrueba = process.argv.includes('--dry-run');
	const forzar = process.argv.includes('--forzar');
	const repo = (leerBandera('repo') ?? process.env.REPO_VIGILADO ?? '').trim();
	const token = (process.env.SHERMAN_PAT ?? process.env.GH_TOKEN ?? '').trim();
	const etiqueta = (leerBandera('etiqueta') ?? ETIQUETA_POR_DEFECTO).trim();
	const esperados = Number(leerBandera('esperados') ?? process.env.RUNNERS_ESPERADOS ?? 0) || 0;
	// `null` si no está configurada, y ese `null` es el que deja todo (huella y mensaje) como antes.
	const grupos = parsearGrupos(leerBandera('esperados-por') ?? process.env.RUNNERS_ESPERADOS_POR);
	const rutaEstado = leerBandera('estado');
	const previo = leerEstadoPrevio(leerBandera('estado-previo') ?? rutaEstado);

	if (!repo) {
		console.error('Falta el repo a vigilar (--repo=owner/nombre o REPO_VIGILADO).');
		process.exit(1);
	}
	if (!token) {
		console.error('Falta el PAT (SHERMAN_PAT), con permiso Administration: Read sobre el repo.');
		process.exit(1);
	}

	let estado;
	let porGrupo = null;
	try {
		const runners = await consultarRunners(repo, token);
		estado = estadoFleet(runners, etiqueta);
		if (grupos) porGrupo = estadoPorGrupo(runners, etiqueta, grupos);
	} catch (error) {
		// Un fallo de la API no es un fleet caído: avisar de eso sería un falso positivo cada vez
		// que GitHub tenga un mal minuto. Se registra y se sale en verde sin tocar el estado.
		console.error(`⚠️  No se pudo consultar los runners de ${repo}: ${error.message}`);
		return;
	}

	console.log(
		`${repo} · etiqueta «${etiqueta}»: ${estado.online}/${estado.total} en línea` +
			(esperados > 0 ? ` (${esperados} esperados)` : '') +
			(estado.caidos.length > 0 ? ` · fuera: ${estado.caidos.join(', ')}` : '')
	);
	if (grupos) {
		console.log(
			Object.entries(grupos)
				.map(
					([g, c]) =>
						`  ${g}: ${porGrupo?.[g]?.online ?? 0}/${c.esperados} registrados ${porGrupo?.[g]?.total ?? 0}` +
						(c.efimero ? ' (efímero: un déficit se confirma en la ronda siguiente)' : '')
				)
				.join('\n')
		);
	}

	const { avisar, sano, huella, faltan, faltanPorGrupo, pendiente } = decidirAviso({
		estado,
		esperados,
		previo,
		forzar,
		grupos,
		porGrupo
	});

	if (rutaEstado && !soloPrueba) {
		// `pendiente` es lo que hace posible la confirmación en dos rondas de los grupos efímeros: sin
		// persistirlo, cada ronda vería el hueco de rotación como si fuera el primero y jamás hablaría.
		writeFileSync(rutaEstado, JSON.stringify({ huella, sano, pendiente }), 'utf8');
	}

	if (!avisar) {
		console.log(
			'Sin cambios respecto a la ronda anterior: no se avisa. (Con --forzar habla igualmente.)'
		);
		return;
	}

	if (forzar) console.log('Aviso forzado: se manda aunque el estado no haya cambiado.');
	const mensaje = construirMensaje({
		repo,
		estado,
		esperados,
		faltan,
		sano,
		forzado: forzar,
		grupos,
		porGrupo,
		faltanPorGrupo
	});
	if (soloPrueba) {
		console.log('\n--- mensaje (dry-run) ---\n' + mensaje + '\n-------------------------');
		return;
	}
	await enviarTelegram(mensaje);
}

// Solo corre al invocarlo directamente: así los helpers se pueden importar sin consultar la API.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	await main();
}
