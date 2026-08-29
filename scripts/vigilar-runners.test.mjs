/**
 * Pruebas de la vigilancia del fleet. Estos scripts no tenían ninguna, y son justo los que fallan
 * en silencio: si `decidirAviso` deja de hablar, el job sale VERDE y no llega ningún mensaje —
 * indistinguible de un fleet sano. Solo se prueban las funciones puras (nada de red).
 *
 * Correr con:  node --test scripts/
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
	construirMensaje,
	decidirAviso,
	estadoFleet,
	estadoPorGrupo,
	evaluarGrupos,
	parsearGrupos
} from './vigilar-runners.mjs';
import { construirInforme } from './estado-runners.mjs';

const GRUPOS = parsearGrupos('linux=12,macos=2!,escritorio=1');

/** Inventario simulado: `n` runners de una plataforma, con las etiquetas tal y como las da GitHub. */
function runners(prefijo, n, etiquetasExtra = [], { online = true } = {}) {
	return Array.from({ length: n }, (_, i) => ({
		name: `${prefijo}-${i + 1}`,
		status: online ? 'online' : 'offline',
		busy: false,
		labels: [{ name: 'sherman' }, ...etiquetasExtra.map((name) => ({ name }))]
	}));
}

const fleetCompleto = () => [
	...runners('lin', 12, ['self-hosted', 'Linux', 'X64']),
	...runners('mac', 2, ['self-hosted', 'macOS', 'ARM64']),
	...runners('win', 1, ['self-hosted', 'Linux', 'escritorio'])
];

test('parsearGrupos lee la sintaxis compacta y la marca de efímero', () => {
	assert.deepEqual(GRUPOS, {
		linux: { esperados: 12, efimero: false },
		macos: { esperados: 2, efimero: true },
		escritorio: { esperados: 1, efimero: false }
	});
	// Sin variable no hay grupos, y ese `null` es lo que conserva el comportamiento de antes.
	assert.equal(parsearGrupos(''), null);
	assert.equal(parsearGrupos(undefined), null);
});

test('estadoPorGrupo casa las etiquetas que GitHub escribe en mayúsculas', () => {
	// `Linux` y `macOS` las pone GitHub sola al registrar el runner: por eso no hubo que
	// re-desplegar los 12 contenedores que ya corrían.
	const porGrupo = estadoPorGrupo(fleetCompleto(), 'sherman', GRUPOS);
	assert.equal(porGrupo.linux.total, 13, 'el runner de escritorio también corre sobre Linux');
	assert.equal(porGrupo.macos.total, 2);
	assert.equal(porGrupo.escritorio.total, 1);
	assert.equal(porGrupo.macos.online, 2);
});

test('estadoPorGrupo exige AND: la etiqueta del fleet Y la del grupo', () => {
	const ajenos = [
		{ name: 'de-otro', status: 'online', labels: [{ name: 'macOS' }] },
		{ name: 'sin-grupo', status: 'online', labels: [{ name: 'sherman' }] }
	];
	const porGrupo = estadoPorGrupo(ajenos, 'sherman', GRUPOS);
	assert.equal(porGrupo.macos.total, 0);
	assert.equal(porGrupo.linux.total, 0);
});

test('sin RUNNERS_ESPERADOS_POR nada cambia: misma huella y mismo mensaje', () => {
	const estado = estadoFleet(fleetCompleto(), 'sherman');
	const d = decidirAviso({ estado, esperados: 12, previo: null });
	// Byte a byte la huella de siempre: `{"caidos":[],"total":15}`. Si esto cambia, todas las
	// cachés de estado del cron quedan invalidadas y el vigía manda un mensaje de más.
	assert.equal(d.huella, JSON.stringify({ caidos: [], total: 15 }));
	const mensaje = construirMensaje({
		repo: 'demeneghi/sherman-svelte',
		estado,
		esperados: 12,
		faltan: d.faltan,
		sano: d.sano,
		forzado: true
	});
	assert.equal(
		mensaje,
		[
			'🔎 <b>Comprobación del vigía</b>',
			'',
			'<b>demeneghi/sherman-svelte</b> — los <code>15</code> runners están en línea.',
			'',
			'Lo pediste a mano; si lees esto, el aviso por Telegram funciona.'
		].join('\n')
	);
});

test('un Mac caído y un Linux de más CAMBIAN la huella (con el contador plano se silenciaba)', () => {
	const antes = fleetCompleto();
	// Se cae un Mac y entra un Linux extra: `caidos` sigue vacío (la VM se desregistra al morir) y el
	// total no se mueve. Con la huella vieja `{caidos,total}` este caso no sonaba NUNCA.
	const despues = [
		...runners('lin', 13, ['self-hosted', 'Linux', 'X64']),
		...runners('mac', 1, ['self-hosted', 'macOS', 'ARM64']),
		...runners('win', 1, ['self-hosted', 'Linux', 'escritorio'])
	];
	const plana = (inv) => JSON.stringify({ caidos: estadoFleet(inv, 'sherman').caidos, total: estadoFleet(inv, 'sherman').total });
	assert.equal(plana(antes), plana(despues), 'la huella de antes no distinguía estos dos fleets');

	const ronda = (inv, previo) =>
		decidirAviso({
			estado: estadoFleet(inv, 'sherman'),
			esperados: 12,
			previo,
			grupos: GRUPOS,
			porGrupo: estadoPorGrupo(inv, 'sherman', GRUPOS)
		});

	const sano = ronda(antes, null);
	// Con el déficit de macOS ya confirmado (viene de la ronda anterior), la huella por grupo sí lo
	// distingue y el vigía habla. La ronda de gracia de los efímeros la cubre el test siguiente.
	const caido = ronda(despues, { huella: sano.huella, sano: true, pendiente: ['macos'] });
	assert.notEqual(caido.huella, sano.huella);
	assert.equal(caido.avisar, true);
	assert.deepEqual(caido.faltanPorGrupo, { macos: 1 });
});

test('un grupo efímero calla en la primera ronda y habla en la segunda', () => {
	const inventario = [
		...runners('lin', 12, ['self-hosted', 'Linux', 'X64']),
		...runners('mac', 1, ['self-hosted', 'macOS', 'ARM64']),
		...runners('win', 1, ['self-hosted', 'Linux', 'escritorio'])
	];
	const comun = {
		estado: estadoFleet(inventario, 'sherman'),
		esperados: 12,
		grupos: GRUPOS,
		porGrupo: estadoPorGrupo(inventario, 'sherman', GRUPOS)
	};
	const completo = fleetCompleto();
	const sanoPrevio = {
		huella: decidirAviso({
			estado: estadoFleet(completo, 'sherman'),
			esperados: 12,
			previo: null,
			grupos: GRUPOS,
			porGrupo: estadoPorGrupo(completo, 'sherman', GRUPOS)
		}).huella,
		sano: true,
		pendiente: []
	};

	// Ronda 1: el slot de macOS pudo estar rotando (60-90 s sin registro). No se avisa.
	const r1 = decidirAviso({ ...comun, previo: sanoPrevio });
	assert.equal(r1.avisar, false);
	assert.equal(r1.sano, true, 'un hueco sin confirmar no cuenta como fleet enfermo');
	assert.deepEqual(r1.faltanPorGrupo, {});
	assert.deepEqual(r1.pendiente, ['macos']);

	// Ronda 2: sigue faltando. Ya no es una rotación.
	const r2 = decidirAviso({ ...comun, previo: { huella: r1.huella, sano: r1.sano, pendiente: r1.pendiente } });
	assert.equal(r2.avisar, true);
	assert.equal(r2.sano, false);
	assert.deepEqual(r2.faltanPorGrupo, { macos: 1 });
});

test('un grupo NO efímero habla en la primera ronda', () => {
	// El de escritorio es un contenedor: si no está registrado, no está rotando, está caído.
	const inventario = [
		...runners('lin', 12, ['self-hosted', 'Linux', 'X64']),
		...runners('mac', 2, ['self-hosted', 'macOS', 'ARM64'])
	];
	const d = decidirAviso({
		estado: estadoFleet(inventario, 'sherman'),
		esperados: 12,
		previo: { huella: 'lo-que-fuera', sano: true, pendiente: [] },
		grupos: GRUPOS,
		porGrupo: estadoPorGrupo(inventario, 'sherman', GRUPOS)
	});
	assert.equal(d.avisar, true);
	assert.deepEqual(d.faltanPorGrupo, { escritorio: 1 });
	assert.deepEqual(d.pendiente, [], 'solo los efímeros dejan pendiente');
});

test('con grupos, el mensaje lleva el desglose por plataforma', () => {
	const inventario = [
		...runners('lin', 12, ['self-hosted', 'Linux', 'X64']),
		...runners('mac', 2, ['self-hosted', 'macOS', 'ARM64'])
	];
	const estado = estadoFleet(inventario, 'sherman');
	const porGrupo = estadoPorGrupo(inventario, 'sherman', GRUPOS);
	const texto = construirMensaje({
		repo: 'demeneghi/sherman-svelte',
		estado,
		esperados: 12,
		faltan: 0,
		sano: false,
		grupos: GRUPOS,
		porGrupo,
		faltanPorGrupo: { escritorio: 1 }
	});
	assert.match(
		texto,
		/Linux <code>12\/12<\/code> · macOS <code>2\/2<\/code> · Escritorio <code>0\/1<\/code>/
	);
	assert.match(texto, /Sin registrar por plataforma: <code>1<\/code> en Escritorio\./);
});

test('evaluarGrupos sin configuración no inventa déficits', () => {
	assert.deepEqual(evaluarGrupos({ grupos: null, porGrupo: null, previo: null }), {
		faltanPorGrupo: {},
		pendiente: [],
		huecoNoConfirmado: 0,
		totalEfimeros: 0
	});
});

test('el informe de estado-runners añade la columna Grupo sin perder los runners sin etiqueta', () => {
	const inventario = [
		...fleetCompleto(),
		{ name: 'huerfano', status: 'online', busy: false, labels: [{ name: 'self-hosted' }] }
	];
	const { texto } = construirInforme({
		repo: 'demeneghi/sherman-svelte',
		runners: inventario,
		etiqueta: 'sherman',
		esperados: 12,
		grupos: GRUPOS
	});
	assert.match(texto, /\| Runner \| Grupo \| Estado \| Ocupado \| Del fleet \|/);
	assert.match(texto, /\| Plataforma \| En línea \| Registrados \| Esperados \| Ocupados \|/);
	assert.match(texto, /`macos` \(efímero\) \| 2 \| 2 \| 2 \| 0 \|/);
	// La sección de runners sin la etiqueta del fleet no se pierde: un runner vivo sin etiqueta no
	// toma ni un job y mirando solo los etiquetados pasaría inadvertido.
	assert.match(texto, /registrados \*\*sin\*\* la etiqueta/);
});

// El reparto REAL de producción (el default de los workflows), que no es el `GRUPOS` de arriba: el
// runner de escritorio corre en un contenedor, así que GitHub le pone `Linux` además de
// `escritorio` y cuenta en LOS DOS grupos. De ahí `linux=13`.
const GRUPOS_PRODUCCION = parsearGrupos('linux=13,macos=2!,escritorio=1');

test('con el reparto de producción, perder un runner Linux del registro SÍ da déficit', () => {
	// El fallo que fija: con `linux=12` sobraba un miembro en el grupo (el de escritorio), así que
	// al desaparecer un Linux del registro el grupo se quedaba en 12 —su cuenta esperada— y
	// `faltanPorGrupo` salía vacío. El vigía callaba ante una máquina perdida, que es exactamente
	// lo que existe para detectar.
	const faltan = (inventario) =>
		evaluarGrupos({
			grupos: GRUPOS_PRODUCCION,
			porGrupo: estadoPorGrupo(inventario, 'sherman', GRUPOS_PRODUCCION),
			previo: {}
		}).faltanPorGrupo;
	const completo = fleetCompleto();
	assert.deepEqual(faltan(completo), {}, 'el fleet completo no debe reportar déficit');
	assert.equal(
		faltan(completo.filter((r) => r.name !== 'lin-1')).linux,
		1,
		'perder un Linux del registro debe dar déficit de 1'
	);
	// Y el contraejemplo, que es lo que hace la prueba no vacua: con `linux=12` el mismo inventario
	// no reporta nada, porque el de escritorio rellena la plaza que dejó el Linux perdido.
	const doce = parsearGrupos('linux=12,macos=2!,escritorio=1');
	assert.deepEqual(
		evaluarGrupos({
			grupos: doce,
			porGrupo: estadoPorGrupo(
				completo.filter((r) => r.name !== 'lin-1'),
				'sherman',
				doce
			),
			previo: {}
		}).faltanPorGrupo,
		{},
		'con linux=12 el fallo queda enmascarado: ese es el motivo del 13'
	);
});
