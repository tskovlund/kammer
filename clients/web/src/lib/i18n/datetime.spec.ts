import { describe, expect, it } from 'vitest';
import { formatRelativeTime } from './datetime';

const now = new Date('2026-07-09T12:00:00Z');

describe('formatRelativeTime', () => {
	it('reports very recent times as "now"', () => {
		expect(formatRelativeTime('2026-07-09T11:59:40Z', 'en', now)).toBe('now');
	});

	it('reports minutes ago in English', () => {
		expect(formatRelativeTime('2026-07-09T11:55:00Z', 'en', now)).toBe('5 minutes ago');
	});

	it('reports hours ago in English', () => {
		expect(formatRelativeTime('2026-07-09T09:00:00Z', 'en', now)).toBe('3 hours ago');
	});

	it('reports future times', () => {
		expect(formatRelativeTime('2026-07-11T12:00:00Z', 'en', now)).toBe('in 2 days');
	});

	it('localizes to Danish', () => {
		// Danish for "5 minutes ago" — asserting it differs from the English form
		// proves the locale is actually threaded through Intl.
		const da = formatRelativeTime('2026-07-09T11:55:00Z', 'da', now);
		expect(da).not.toBe('5 minutes ago');
		expect(da).toContain('5');
	});
});
