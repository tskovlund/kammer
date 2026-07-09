import { detectLocale, translate, type Locale, type MessageKey } from './format.js';

const STORAGE_KEY = 'kammer:locale';

function initialLocale(): Locale {
	if (typeof localStorage !== 'undefined') {
		const stored = localStorage.getItem(STORAGE_KEY);
		if (stored === 'en' || stored === 'da') return stored;
	}
	if (typeof navigator !== 'undefined') {
		return detectLocale(navigator.languages ?? [navigator.language]);
	}
	return 'en';
}

let current = $state<Locale>(initialLocale());

/**
 * Reactive locale: from `navigator.language` by default, persisted only
 * once the user picks one explicitly (the You tab) — so a detected
 * locale keeps following the browser setting until overridden.
 */
export const i18n = {
	get locale(): Locale {
		return current;
	},
	setLocale(locale: Locale): void {
		current = locale;
		if (typeof localStorage !== 'undefined') localStorage.setItem(STORAGE_KEY, locale);
	}
};

/** Translate a message key in the current locale, with `{name}` params. */
export function t(key: MessageKey, params?: Record<string, string>): string {
	return translate(current, key, params);
}
