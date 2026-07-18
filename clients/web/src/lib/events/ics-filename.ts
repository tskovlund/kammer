/**
 * A title-derived download name for a single-event `.ics` (issue #315).
 *
 * The browser's `download` attribute wins over the server's
 * `Content-Disposition` for a blob download, so this must agree with the
 * server's `Kammer.Calendar.ICS.filename/1`: same op order (transliterate
 * → collapse non-slug runs to a single dash → cap at 60 → trim), same
 * Nordic transliteration, same `kammer.ics` fallback when nothing
 * slug-safe survives. Keep the two in lockstep — `ics-filename.spec.ts`
 * mirrors the server's `ics_test.exs` cases.
 */
export function icsFilename(title: string): string {
	const slug = title
		.toLowerCase()
		.replace(/[æä]/gu, 'ae')
		.replace(/[øö]/gu, 'oe')
		.replace(/å/gu, 'aa')
		.replace(/[éèê]/gu, 'e')
		.replace(/ü/gu, 'ue')
		.replace(/[^a-z0-9]+/gu, '-')
		.slice(0, 60)
		.replace(/^-+|-+$/g, '');
	return slug ? `${slug}.ics` : 'kammer.ics';
}
