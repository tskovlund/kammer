export type ThemePreference = 'system' | 'light' | 'dark';

const STORAGE_KEY = 'kammer:theme';

/** Paper background per theme — kept in step with layout.css tokens. */
const THEME_COLORS = { light: '#f6f4f0', dark: '#181512' } as const;

function initialPreference(): ThemePreference {
	if (typeof localStorage !== 'undefined') {
		const stored = localStorage.getItem(STORAGE_KEY);
		if (stored === 'light' || stored === 'dark') return stored;
	}
	return 'system';
}

function apply(preference: ThemePreference): void {
	if (typeof document === 'undefined') return;
	const root = document.documentElement;
	if (preference === 'system') {
		delete root.dataset.theme;
	} else {
		root.dataset.theme = preference;
	}
	// Keep the browser chrome (address bar / PWA title bar) color in step:
	// the two media-scoped <meta name="theme-color"> tags are correct for
	// "system"; a forced theme pins both to the same paper color.
	for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
		const scheme = meta.getAttribute('media')?.includes('dark') ? 'dark' : 'light';
		meta.setAttribute('content', THEME_COLORS[preference === 'system' ? scheme : preference]);
	}
}

let current = $state<ThemePreference>(initialPreference());

// The pre-hydration script stamps data-theme for first paint, but it
// leaves the media-scoped theme-color metas at their system defaults —
// a forced theme must pin them on load, not only on the next toggle.
apply(current);

/**
 * Theme preference: `prefers-color-scheme` by default, with a manual
 * override persisted in localStorage and stamped on `<html data-theme>`.
 * First paint is handled by the pre-hydration script in app.html; this
 * store owns every change after that.
 */
export const theme = {
	get preference(): ThemePreference {
		return current;
	},
	setPreference(preference: ThemePreference): void {
		current = preference;
		if (typeof localStorage !== 'undefined') {
			if (preference === 'system') {
				localStorage.removeItem(STORAGE_KEY);
			} else {
				localStorage.setItem(STORAGE_KEY, preference);
			}
		}
		apply(preference);
	}
};
