import { describe, expect, it } from 'vitest';
import { communityAccentStyle, contrastRatio, deriveAccentTokens } from './accent.js';

// The token backgrounds from routes/layout.css, restated literally on
// purpose: if the palette there drifts without accent.ts following,
// these assertions catch it.
const LIGHT_BACKGROUNDS = ['#f6f4f0', '#fcfbf8']; // light --paper, --surface
const DARK_BACKGROUNDS = ['#181512', '#201c18']; // dark --paper, --surface
const FLOOR = 4.5;

/** Assert every pair the derivation promises holds WCAG AA. */
function expectSafe(tokens: NonNullable<ReturnType<typeof deriveAccentTokens>>): void {
	for (const background of LIGHT_BACKGROUNDS) {
		expect(contrastRatio(tokens.light.accent, background)).toBeGreaterThanOrEqual(FLOOR);
	}
	for (const background of DARK_BACKGROUNDS) {
		expect(contrastRatio(tokens.dark.accent, background)).toBeGreaterThanOrEqual(FLOOR);
	}
	expect(contrastRatio(tokens.light.accentInk, tokens.light.accent)).toBeGreaterThanOrEqual(FLOOR);
	expect(contrastRatio(tokens.dark.accentInk, tokens.dark.accent)).toBeGreaterThanOrEqual(FLOOR);
}

/** hsl → #rrggbb, for sweeping inputs across the hue wheel. */
function hex(h: number, s: number, l: number): string {
	const f = (n: number) => {
		const k = (n + h / 30) % 12;
		const a = s * Math.min(l, 1 - l);
		const value = l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
		return Math.round(value * 255)
			.toString(16)
			.padStart(2, '0');
	};
	return `#${f(0)}${f(8)}${f(4)}`;
}

describe('deriveAccentTokens', () => {
	it('ships an already-safe color untouched in light and lifts only its dark twin', () => {
		// The default light accent: 6.1:1 on light paper, so the light
		// palette must be byte-identical — minimal intervention is the
		// contract, not "always recompute".
		const tokens = deriveAccentTokens('#8a4b24')!;
		expect(tokens.light.accent).toBe('#8a4b24');
		// …but 2.7:1 on dark paper, so the dark twin must be lightened.
		expect(tokens.dark.accent).not.toBe('#8a4b24');
		expectSafe(tokens);
	});

	it('darkens a near-white color for the light palette and keeps it for the dark one', () => {
		const tokens = deriveAccentTokens('#ffffff')!;
		expect(tokens.light.accent).not.toBe('#ffffff');
		expect(tokens.dark.accent).toBe('#ffffff');
		expectSafe(tokens);
	});

	it('lightens a near-black color for the dark palette and keeps it for the light one', () => {
		const tokens = deriveAccentTokens('#000000')!;
		expect(tokens.light.accent).toBe('#000000');
		expect(tokens.dark.accent).not.toBe('#000000');
		expectSafe(tokens);
	});

	it('holds the AA floor across the hue wheel at every extreme', () => {
		// The property the module exists for: whatever an admin stores,
		// every derived pair clears 4.5:1 in both palettes. Sweep hues at
		// low/high saturation crossed with near-black, mid, and near-white
		// lightness — including the mid-luminance band where neither pure
		// white nor pure black ink alone would reach 4.5:1.
		for (let hue = 0; hue < 360; hue += 30) {
			for (const saturation of [0.15, 0.95]) {
				for (const lightness of [0.03, 0.5, 0.97]) {
					const input = hex(hue, saturation, lightness);
					const tokens = deriveAccentTokens(input);
					expect(tokens, `no tokens for ${input}`).not.toBeNull();
					expectSafe(tokens!);
				}
			}
		}
	});

	it('falls back to null — no override, default accent — for anything unparseable', () => {
		for (const stored of [null, undefined, '', '8a4b24', '#8a4', '#8a4b2g', 'tomato']) {
			expect(deriveAccentTokens(stored), `expected null for ${String(stored)}`).toBeNull();
		}
	});
});

describe('communityAccentStyle', () => {
	it('emits both palettes as the custom properties the layout.css bridge consumes', () => {
		const tokens = deriveAccentTokens('#3e6b48')!;
		const style = communityAccentStyle(tokens);
		expect(style).toContain(`--community-accent-light: ${tokens.light.accent}`);
		expect(style).toContain(`--community-accent-ink-light: ${tokens.light.accentInk}`);
		expect(style).toContain(`--community-accent-dark: ${tokens.dark.accent}`);
		expect(style).toContain(`--community-accent-ink-dark: ${tokens.dark.accentInk}`);
	});
});
