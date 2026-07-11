/**
 * Option values for the profile's timezone select: the browser's IANA
 * zone list, with the SAVED zone prepended when the browser doesn't
 * list it — tzdata link names like `US/Pacific` validate server-side
 * (`DateTime.now/1`) but are absent from `Intl`'s canonical-only list,
 * and opening the form must never silently rewrite a stored value.
 *
 * Keyed off the saved value, never the live selection: the stored zone
 * must stay pickable while the user browses other options (a derived
 * list reading the live binding drops it the moment they select
 * something else, making the original unrecoverable without a reload).
 */
export function timezoneOptions(saved: string | null, zones: readonly string[]): string[] {
	return saved && !zones.includes(saved) ? [saved, ...zones] : [...zones];
}

/** The browser's IANA zone list; empty where unsupported (older engines). */
export function browserTimezones(): readonly string[] {
	return typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [];
}
