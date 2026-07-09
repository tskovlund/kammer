// Rasterizes the SVG marks in static/icons/ into the PNG sizes the
// platforms actually require: iOS home-screen ignores manifest icons
// entirely (needs apple-touch-icon 180px PNG), and Chrome's install
// heuristics want raster 192/512 entries. Run manually after changing
// an icon SVG: `node scripts/generate-icons.mjs` — outputs are
// committed, not built on the fly.
import { Resvg } from '@resvg/resvg-js';
import { readFileSync, writeFileSync } from 'node:fs';

const jobs = [
	{ src: 'static/icons/icon.svg', out: 'static/icons/icon-192.png', size: 192 },
	{ src: 'static/icons/icon.svg', out: 'static/icons/icon-512.png', size: 512 },
	{ src: 'static/icons/icon-maskable.svg', out: 'static/icons/icon-maskable-512.png', size: 512 },
	{ src: 'static/icons/icon.svg', out: 'static/icons/apple-touch-icon.png', size: 180 }
];

for (const { src, out, size } of jobs) {
	const svg = readFileSync(src, 'utf8');
	const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: size } });
	writeFileSync(out, resvg.render().asPng());
	console.log(`${out} (${size}px)`);
}
