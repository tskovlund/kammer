import da from './da.json';
import en from './en.json';

/**
 * Hand-rolled, typed i18n core — deliberately not a dependency. Kammer
 * ships EN + DA from day one (SPEC.md §20) and needs nothing beyond
 * typed keys and `{name}` interpolation, so a library would be pure
 * weight. English is the source catalog: `MessageKey` derives from its
 * keys, and typing `catalogs` as `Record<Locale, Record<MessageKey,
 * string>>` makes a missing Danish key a compile error, not a runtime
 * fallback surprise.
 */
export const locales = ['en', 'da'] as const;
export type Locale = (typeof locales)[number];
export type MessageKey = keyof typeof en;

const catalogs: Record<Locale, Record<MessageKey, string>> = { en, da };

export function translate(
	locale: Locale,
	key: MessageKey,
	params?: Record<string, string>
): string {
	const template = catalogs[locale][key];
	if (!params) return template;
	return template.replace(/\{(\w+)\}/g, (match, name: string) => params[name] ?? match);
}

/**
 * Picks the first supported language from the browser's preference list
 * (`navigator.languages` shape — `"da-DK"` counts as Danish), falling
 * back to English.
 */
export function detectLocale(languages: readonly string[]): Locale {
	for (const language of languages) {
		const base = language.toLowerCase().split('-')[0];
		if ((locales as readonly string[]).includes(base)) return base as Locale;
	}
	return 'en';
}
