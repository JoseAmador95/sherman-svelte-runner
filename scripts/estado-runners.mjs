/**
 * Foto del fleet, a petición. NO avisa por Telegram y NO toca el estado del anti-spam: solo mira y
 * cuenta lo que ve.
 *
 * Es el complemento del vigía, no un duplicado: aquel responde «¿ha cambiado algo?» y habla por
 * Telegram; este responde «¿qué está pasando ahora mismo?» y lo escribe en el resumen del job. Por
 * eso lista TODOS los runners del repo y no solo los del fleet — un runner al que se le cayó la
 * etiqueta sigue registrado y en línea, pero no toma ni un job, y mirando solo los etiquetados
 * pasaría inadvertido.
 *
 * Uso:
 *   SHERMAN_PAT=github_pat_… node scripts/estado-runners.mjs --repo=demeneghi/sherman-svelte
 */
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { consultarRunners, estadoPorGrupo, parsearGrupos } from './vigilar-runners.mjs';

const ETIQUETA_POR_DEFECTO = 'sherman';

function leerBandera(nombre, porDefecto = null) {
	const prefijo = `--${nombre}=`;
	const arg = process.argv.find((a) => a.startsWith(prefijo));
	return arg ? arg.slice(prefijo.length) : porDefecto;
}

/** Escapa lo que rompe una tabla de Markdown; los nombres de runner los elige quien despliega. */
function celda(texto) {
	return String(texto ?? '—').replaceAll('|', '\\|');
}

/**
 * Arma el informe en Markdown. Puro: recibe el inventario ya consultado, así se puede probar sin red.
 */
export function construirInforme({ repo, runners, etiqueta, esperados, grupos = null }) {
	const objetivo = String(etiqueta).toLowerCase();
	const marcados = (runners ?? []).map((r) => ({
		nombre: r?.name ?? '(sin nombre)',
		online: r?.status === 'online',
		ocupado: Boolean(r?.busy),
		delFleet: (r?.labels ?? []).some((l) => String(l?.name ?? '').toLowerCase() === objetivo),
		etiquetas: (r?.labels ?? []).map((l) => l?.name).filter(Boolean)
	}));
	// A qué grupo pertenece cada runner. Se resuelve con las MISMAS etiquetas que usa el vigía para
	// contar, así que si aquí sale «—» es que allí tampoco cuenta para ningún grupo.
	const nombresGrupo = grupos ? Object.keys(grupos) : [];
	for (const r of marcados) {
		const suyas = r.etiquetas.map((e) => String(e).toLowerCase());
		r.grupo = nombresGrupo.find((g) => suyas.includes(g.toLowerCase())) ?? null;
	}
	marcados.sort((a, b) => a.nombre.localeCompare(b.nombre));

	const delFleet = marcados.filter((r) => r.delFleet);
	const online = delFleet.filter((r) => r.online).length;
	const ocupados = delFleet.filter((r) => r.online && r.ocupado).length;
	const faltan = esperados > 0 ? Math.max(0, esperados - delFleet.length) : 0;
	const sinEtiqueta = marcados.filter((r) => !r.delFleet);

	const l = [
		`## Fleet de \`${repo}\``,
		'',
		`Etiqueta \`${etiqueta}\`: **${online}` +
			(esperados > 0 ? ` de ${esperados} esperados` : ` de ${delFleet.length}`) +
			`** en línea, ${ocupados} ${ocupados === 1 ? 'ocupado' : 'ocupados'}.`,
		''
	];

	// Resumen por plataforma: el conteo global no distingue un Mac caído de un Linux caído, y son
	// dos problemas distintos (dos slots de macOS son un límite duro de licencia de Apple; los de
	// Linux se reponen añadiendo contenedores).
	const porGrupo = grupos ? estadoPorGrupo(runners ?? [], etiqueta, grupos) : null;
	if (porGrupo && marcados.length > 0) {
		l.push(
			'| Plataforma | En línea | Registrados | Esperados | Ocupados |',
			'| --- | --- | --- | --- | --- |'
		);
		for (const [nombre, conf] of Object.entries(grupos)) {
			const g = porGrupo[nombre] ?? { total: 0, online: 0, ocupados: 0 };
			const corto = conf.esperados > 0 && g.total < conf.esperados;
			l.push(
				// El aviso va DENTRO de la última celda: colgado detrás del `|` de cierre rompe la tabla.
				`| \`${celda(nombre)}\`${conf.efimero ? ' (efímero)' : ''} | ${g.online} | ` +
					`${g.total}${corto ? ' ⚠️' : ''} | ${conf.esperados || '—'} | ${g.ocupados} |`
			);
		}
		l.push('');
	}

	if (marcados.length === 0) {
		l.push('> El repo no tiene ningún runner registrado.');
		return { texto: l.join('\n'), online, total: delFleet.length, faltan };
	}

	l.push('| Runner | Grupo | Estado | Ocupado | Del fleet |', '| --- | --- | --- | --- | --- |');
	for (const r of marcados) {
		l.push(
			`| \`${celda(r.nombre)}\` | ${r.grupo ? `\`${celda(r.grupo)}\`` : '—'} | ${
				r.online ? '🟢 en línea' : '🔴 fuera'
			} | ${r.ocupado ? 'sí' : '—'} | ${
				r.delFleet ? 'sí' : `no (${celda(r.etiquetas.join(', '))})`
			} |`
		);
	}

	if (faltan > 0) {
		l.push(
			'',
			`> ⚠️ Faltan **${faltan}** por registrar: su contenedor pudo morir del todo, no solo quedarse \`offline\`.`
		);
	}
	if (sinEtiqueta.length > 0) {
		l.push(
			'',
			`> ⚠️ Hay **${sinEtiqueta.length}** registrados **sin** la etiqueta \`${etiqueta}\`: están vivos pero no toman jobs de la CI.`
		);
	}
	if (online === 0 && delFleet.length > 0) {
		l.push(
			'',
			'> 🔴 Sin ningún runner en línea, los jobs de la CI **se quedan en cola** (no hay respaldo de pago). GitHub los descarta a las 24 h.'
		);
	}

	return { texto: l.join('\n'), online, total: delFleet.length, faltan };
}

async function main() {
	const repo = (leerBandera('repo') ?? process.env.REPO_VIGILADO ?? '').trim();
	const token = (process.env.SHERMAN_PAT ?? process.env.GH_TOKEN ?? '').trim();
	const etiqueta = (leerBandera('etiqueta') ?? ETIQUETA_POR_DEFECTO).trim();
	const esperados = Number(leerBandera('esperados') ?? process.env.RUNNERS_ESPERADOS ?? 0) || 0;
	const grupos = parsearGrupos(leerBandera('esperados-por') ?? process.env.RUNNERS_ESPERADOS_POR);

	if (!repo) {
		console.error('Falta el repo (--repo=owner/nombre o REPO_VIGILADO).');
		process.exit(1);
	}
	if (!token) {
		console.error('Falta el PAT (SHERMAN_PAT), con permiso Administration: Read sobre el repo.');
		process.exit(1);
	}

	// Aquí SÍ se falla en rojo si la API no responde: se pidió una foto a mano y no hay foto. El
	// vigía hace lo contrario (sale en verde) porque un mal minuto de GitHub no es un fleet caído.
	const runners = await consultarRunners(repo, token);
	const { texto } = construirInforme({ repo, runners, etiqueta, esperados, grupos });

	console.log(texto);
	if (process.env.GITHUB_STEP_SUMMARY) {
		appendFileSync(process.env.GITHUB_STEP_SUMMARY, texto + '\n', 'utf8');
	}
}

// Solo corre al invocarlo directamente: así `construirInforme` se puede importar y probar sin red
// (mismo guardián que `vigilar-runners.mjs`).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	await main();
}
