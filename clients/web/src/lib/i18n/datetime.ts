import type { Locale } from './format.js';

/**
 * Locale-aware time formatting for the feed. Kept as pure functions taking an
 * explicit locale (and, for relative time, an explicit `now`) so the "3
 * minutes ago" logic is unit-testable without a clock or a component.
 */

const RELATIVE_THRESHOLDS: { limit: number; divisor: number; unit: Intl.RelativeTimeFormatUnit }[] =
	[
		{ limit: 60, divisor: 1, unit: 'second' },
		{ limit: 3600, divisor: 60, unit: 'minute' },
		{ limit: 86_400, divisor: 3600, unit: 'hour' },
		{ limit: 604_800, divisor: 86_400, unit: 'day' },
		{ limit: 2_629_800, divisor: 604_800, unit: 'week' },
		{ limit: 31_557_600, divisor: 2_629_800, unit: 'month' }
	];

/** "just now" / "5 minutes ago" / "in 3 days", localized. */
export function formatRelativeTime(iso: string, locale: Locale, now: Date = new Date()): string {
	const then = new Date(iso).getTime();
	const deltaSeconds = Math.round((then - now.getTime()) / 1000);
	const absolute = Math.abs(deltaSeconds);
	const formatter = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });

	if (absolute < 45) return formatter.format(0, 'second').replace(/^0\s*/, '') || 'now';

	for (const { limit, divisor, unit } of RELATIVE_THRESHOLDS) {
		if (absolute < limit) {
			return formatter.format(Math.round(deltaSeconds / divisor), unit);
		}
	}
	return formatter.format(Math.round(deltaSeconds / 31_557_600), 'year');
}

/** An absolute date+time, localized — used on events and as a hover title. */
export function formatDateTime(iso: string, locale: Locale): string {
	return new Intl.DateTimeFormat(locale, {
		dateStyle: 'medium',
		timeStyle: 'short'
	}).format(new Date(iso));
}

/** A date without the time — for all-day events and date headings. */
export function formatDate(iso: string, locale: Locale): string {
	return new Intl.DateTimeFormat(locale, { dateStyle: 'medium' }).format(new Date(iso));
}

/** The time without the date — for agenda rows already grouped under a day. */
export function formatTime(iso: string, locale: Locale): string {
	return new Intl.DateTimeFormat(locale, { timeStyle: 'short' }).format(new Date(iso));
}
