import { describe, expect, it } from 'vitest';
import { icsFilename } from './ics-filename';

// Mirrors the server's `test/kammer/calendar/ics_test.exs` — the two
// derivations must agree, since the blob download's `download` attribute
// wins over the server's Content-Disposition (issue #315).
describe('icsFilename', () => {
	it('transliterates Nordic and common accented letters to ASCII', () => {
		expect(icsFilename('Generalprøve')).toBe('generalproeve.ics');
		expect(icsFilename('Sommerfest på taget')).toBe('sommerfest-paa-taget.ics');
		expect(icsFilename('Café Ötzi')).toBe('cafe-oetzi.ics');
	});

	it('collapses every non-slug run to a single dash and trims the ends', () => {
		expect(icsFilename('Åbning; med, komma!')).toBe('aabning-med-komma.ics');
		expect(icsFilename('  spaced  out  ')).toBe('spaced-out.ics');
	});

	it('falls back to kammer.ics when nothing slug-safe survives', () => {
		expect(icsFilename('🎉🎊')).toBe('kammer.ics');
		expect(icsFilename('---')).toBe('kammer.ics');
		expect(icsFilename('   ')).toBe('kammer.ics');
		expect(icsFilename('')).toBe('kammer.ics');
	});

	it('caps the slug so a runaway title stays bounded', () => {
		expect(icsFilename('a'.repeat(100))).toBe(`${'a'.repeat(60)}.ics`);
	});
});
