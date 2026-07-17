/**
 * Per-community accent derivation (issue #321, SPEC §21): "branding is
 * structural — switching communities re-tints the interface", with
 * computed contrast safety for any admin-chosen accent.
 *
 * From a community's stored `accent_color` this derives the accent
 * token pair (`--accent`, `--accent-ink`) for BOTH palettes — the two
 * tokens the whole UI consumes; hover/active shades come from the
 * existing opacity modifiers (`bg-accent/90`, `bg-accent/10`, …), so
 * they re-tint for free once `--accent` does. Every derived pair holds
 * WCAG AA (≥ 4.5:1):
 *
 * - the accent against the theme's `--paper` AND `--surface` (it is
 *   used directly as link/control text on both), darkened for the
 *   light palette / lightened for the dark one only as far as needed,
 *   so a color that is already safe ships untouched;
 * - the accent-ink against the accent (`bg-accent text-accent-ink`
 *   buttons) — near-paper-white in the light palette, a near-black
 *   shade of the same hue in the dark one, mirroring the defaults.
 *
 * Pure functions, no DOM: the application layer is
 * `CommunityAccent.svelte` + the `[data-community-accent]` bridge in
 * `routes/layout.css`. Anything unparseable — and the structurally
 * unreachable case where no adjustment can clear the floor — returns
 * `null`, which means "apply no override": the default tokens stay,
 * so a missing/invalid stored color can never regress the UI.
 */

/** One theme's derived accent tokens, as `#rrggbb` hex. */
export interface AccentPalette {
	accent: string;
	accentInk: string;
}

/** The full derivation result: one palette per theme. */
export interface AccentTokens {
	light: AccentPalette;
	dark: AccentPalette;
}

/** WCAG AA for normal text — the floor for every pair derived here. */
const CONTRAST_FLOOR = 4.5;

// The backgrounds the accent must stay readable on, mirroring the
// token blocks in routes/layout.css (kept in step by the unit tests,
// which assert against these literal values independently).
const LIGHT_BACKGROUNDS = ['#f6f4f0', '#fcfbf8'] as const; // --paper, --surface
const DARK_BACKGROUNDS = ['#181512', '#201c18'] as const; // --paper, --surface

// The default light `--accent-ink` is the light surface color; keep
// that flavor for derived accents (guaranteed to clear the floor once
// the accent itself is clamped against the near-white backgrounds).
const LIGHT_INK = '#fcfbf8';

// The default dark `--accent-ink` (#241505) is a near-black shade of
// the accent's own hue — mirror that: start the derived dark ink at
// this lightness and darken further only if the floor demands it.
const DARK_INK_LIGHTNESS = 0.08;

/** Binary-search resolution: finer than one 8-bit channel step. */
const LIGHTNESS_STEP = 1 / 512;

interface Rgb {
	r: number;
	g: number;
	b: number;
}

interface Hsl {
	h: number;
	s: number;
	l: number;
}

function parseHex(hex: string): Rgb | null {
	// Strict `#rrggbb` — the exact format the server validates
	// (`Kammer.Communities.Community`'s @accent_color_format).
	if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return null;
	return {
		r: parseInt(hex.slice(1, 3), 16),
		g: parseInt(hex.slice(3, 5), 16),
		b: parseInt(hex.slice(5, 7), 16)
	};
}

function rgbToHex({ r, g, b }: Rgb): string {
	const channel = (value: number) => value.toString(16).padStart(2, '0');
	return `#${channel(r)}${channel(g)}${channel(b)}`;
}

function rgbToHsl({ r, g, b }: Rgb): Hsl {
	const red = r / 255;
	const green = g / 255;
	const blue = b / 255;
	const max = Math.max(red, green, blue);
	const min = Math.min(red, green, blue);
	const l = (max + min) / 2;
	const delta = max - min;
	if (delta === 0) return { h: 0, s: 0, l };
	const s = delta / (1 - Math.abs(2 * l - 1));
	let h: number;
	if (max === red) h = ((green - blue) / delta + (green < blue ? 6 : 0)) * 60;
	else if (max === green) h = ((blue - red) / delta + 2) * 60;
	else h = ((red - green) / delta + 4) * 60;
	return { h, s, l };
}

function hslToRgb({ h, s, l }: Hsl): Rgb {
	const chroma = (1 - Math.abs(2 * l - 1)) * s;
	const huePrime = h / 60;
	const x = chroma * (1 - Math.abs((huePrime % 2) - 1));
	let red = 0;
	let green = 0;
	let blue = 0;
	if (huePrime < 1) [red, green] = [chroma, x];
	else if (huePrime < 2) [red, green] = [x, chroma];
	else if (huePrime < 3) [green, blue] = [chroma, x];
	else if (huePrime < 4) [green, blue] = [x, chroma];
	else if (huePrime < 5) [red, blue] = [x, chroma];
	else [red, blue] = [chroma, x];
	const m = l - chroma / 2;
	const channel = (value: number) => Math.round(Math.min(1, Math.max(0, value + m)) * 255);
	return { r: channel(red), g: channel(green), b: channel(blue) };
}

function relativeLuminance({ r, g, b }: Rgb): number {
	const linear = (value: number) => {
		const scaled = value / 255;
		return scaled <= 0.04045 ? scaled / 12.92 : Math.pow((scaled + 0.055) / 1.055, 2.4);
	};
	return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

/**
 * WCAG 2.x contrast ratio between two `#rrggbb` colors, 1..21.
 * Throws on malformed input — callers here only pass validated hex.
 */
export function contrastRatio(hexA: string, hexB: string): number {
	const a = parseHex(hexA);
	const b = parseHex(hexB);
	if (!a || !b) throw new Error(`contrastRatio: invalid hex color (${hexA}, ${hexB})`);
	const lumA = relativeLuminance(a);
	const lumB = relativeLuminance(b);
	const [lighter, darker] = lumA >= lumB ? [lumA, lumB] : [lumB, lumA];
	return (lighter + 0.05) / (darker + 0.05);
}

function clearsFloor(hex: string, backgrounds: readonly string[]): boolean {
	return backgrounds.every((background) => contrastRatio(hex, background) >= CONTRAST_FLOOR);
}

/**
 * The light-palette accent: the stored color, darkened only as far as
 * needed to clear the floor against the near-white backgrounds. The
 * predicate is evaluated on the quantized hex (what CSS will actually
 * render), and lightness 0 (black) always passes, so the search always
 * lands on a verified-passing value.
 */
function darkenToFloor(hsl: Hsl): string {
	const candidate = rgbToHex(hslToRgb(hsl));
	if (clearsFloor(candidate, LIGHT_BACKGROUNDS)) return candidate;
	let passing = 0;
	let failing = hsl.l;
	while (failing - passing > LIGHTNESS_STEP) {
		const mid = (passing + failing) / 2;
		if (clearsFloor(rgbToHex(hslToRgb({ ...hsl, l: mid })), LIGHT_BACKGROUNDS)) passing = mid;
		else failing = mid;
	}
	return rgbToHex(hslToRgb({ ...hsl, l: passing }));
}

/**
 * The dark-palette accent: the same hue, lightened only as far as
 * needed against the near-black backgrounds (the same move that takes
 * the default #8a4b24 to its dark twin). Lightness 1 (white) always
 * passes, so this too always lands on a verified-passing value.
 */
function lightenToFloor(hsl: Hsl): string {
	const candidate = rgbToHex(hslToRgb(hsl));
	if (clearsFloor(candidate, DARK_BACKGROUNDS)) return candidate;
	let failing = hsl.l;
	let passing = 1;
	while (passing - failing > LIGHTNESS_STEP) {
		const mid = (passing + failing) / 2;
		if (clearsFloor(rgbToHex(hslToRgb({ ...hsl, l: mid })), DARK_BACKGROUNDS)) passing = mid;
		else failing = mid;
	}
	return rgbToHex(hslToRgb({ ...hsl, l: passing }));
}

/**
 * The dark-palette ink: a near-black shade of the accent's hue,
 * darkened further only if the floor against the derived accent
 * demands it (black always passes once the accent is clamped light
 * enough for the dark backgrounds, so the search cannot miss).
 */
function darkInkFor(accent: string, hsl: Hsl): string {
	const shade = (l: number) => rgbToHex(hslToRgb({ ...hsl, l }));
	const passes = (l: number) => contrastRatio(shade(l), accent) >= CONTRAST_FLOOR;
	if (passes(DARK_INK_LIGHTNESS)) return shade(DARK_INK_LIGHTNESS);
	let passing = 0;
	let failing = DARK_INK_LIGHTNESS;
	while (failing - passing > LIGHTNESS_STEP) {
		const mid = (passing + failing) / 2;
		if (passes(mid)) passing = mid;
		else failing = mid;
	}
	return shade(passing);
}

/**
 * Derive both palettes' accent tokens from a community's stored
 * `accent_color`. Returns `null` — meaning "apply no override, keep
 * the default tokens" — for anything unparseable, and as a defensive
 * last resort if a derived palette somehow failed its floor (the
 * clamps make that unreachable, but the fallback is the contract:
 * an unsafe stored color must never ship unsafe tokens).
 */
export function deriveAccentTokens(accentColor: string | null | undefined): AccentTokens | null {
	if (!accentColor) return null;
	const rgb = parseHex(accentColor);
	if (!rgb) return null;
	const hsl = rgbToHsl(rgb);

	const lightAccent = darkenToFloor(hsl);
	const darkAccent = lightenToFloor(hsl);
	// Guaranteed by the accent clamp: an accent that holds 4.5:1 against
	// the near-white backgrounds is dark enough for near-white ink.
	const lightInk = contrastRatio(LIGHT_INK, lightAccent) >= CONTRAST_FLOOR ? LIGHT_INK : '#ffffff';
	const darkInk = darkInkFor(darkAccent, hsl);

	const tokens: AccentTokens = {
		light: { accent: lightAccent, accentInk: lightInk },
		dark: { accent: darkAccent, accentInk: darkInk }
	};

	const safe =
		clearsFloor(tokens.light.accent, LIGHT_BACKGROUNDS) &&
		clearsFloor(tokens.dark.accent, DARK_BACKGROUNDS) &&
		contrastRatio(tokens.light.accentInk, tokens.light.accent) >= CONTRAST_FLOOR &&
		contrastRatio(tokens.dark.accentInk, tokens.dark.accent) >= CONTRAST_FLOOR;
	return safe ? tokens : null;
}

/**
 * The inline-style declaration `CommunityAccent.svelte` stamps on its
 * wrapper: both palettes at once, as `--community-accent-*` custom
 * properties. The `[data-community-accent]` rules in routes/layout.css
 * map them onto `--accent`/`--accent-ink` per theme, so light/dark
 * switching (including a live OS switch under "system") stays purely
 * in CSS — no re-derivation, no theme listener, no flash.
 */
export function communityAccentStyle(tokens: AccentTokens): string {
	return [
		`--community-accent-light: ${tokens.light.accent}`,
		`--community-accent-ink-light: ${tokens.light.accentInk}`,
		`--community-accent-dark: ${tokens.dark.accent}`,
		`--community-accent-ink-dark: ${tokens.dark.accentInk}`
	].join('; ');
}
