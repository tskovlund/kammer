import { describe, expect, it } from 'vitest';
import { timezoneOptions } from './timezones';

describe('timezoneOptions', () => {
	it('prepends a saved zone the browser list lacks', () => {
		// tzdata link names (US/Pacific) validate server-side but are absent
		// from Intl's canonical list. NOTE: this pins only the helper's
		// contract — the saved-vs-live-selection property lives in the page
		// wiring (profile/+page.svelte passes `profile?.timezone`, never the
		// live `timezone` binding), which no test currently pins.
		expect(timezoneOptions('US/Pacific', ['Europe/Copenhagen', 'America/Los_Angeles'])).toEqual([
			'US/Pacific',
			'Europe/Copenhagen',
			'America/Los_Angeles'
		]);
	});

	it('never duplicates a saved zone the list already carries', () => {
		expect(timezoneOptions('Europe/Copenhagen', ['Europe/Copenhagen', 'Etc/UTC'])).toEqual([
			'Europe/Copenhagen',
			'Etc/UTC'
		]);
	});

	it('leaves the list untouched with no saved zone', () => {
		expect(timezoneOptions(null, ['Etc/UTC'])).toEqual(['Etc/UTC']);
	});
});
