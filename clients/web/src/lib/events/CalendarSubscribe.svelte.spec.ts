import { afterEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

import CalendarSubscribe from './CalendarSubscribe.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

describe('CalendarSubscribe', () => {
	it('lazily reveals the feed URL and a webcal:// open link on click', async () => {
		const load = vi.fn().mockResolvedValue({
			token: 'tok',
			url: 'https://kammer.example.com/calendar/user/tok.ics'
		});
		render(CalendarSubscribe, { props: { load, label: 'Subscribe', id: 'cal' } });

		// Lazy: the token (which the server mints on fetch) isn't requested
		// until the user asks for it.
		expect(load).not.toHaveBeenCalled();
		await fireEvent.click(document.querySelector('#cal-reveal')!);

		await waitFor(() => expect(document.querySelector('#cal')).toBeTruthy());
		// The revealed URL is exactly the feed URL — no stray whitespace in the
		// select-all block.
		expect(document.querySelector('#cal')?.textContent).toBe(
			'https://kammer.example.com/calendar/user/tok.ics'
		);
		// The "open" link scheme-swaps https → webcal:// for one-tap add.
		expect(screen.getByText('Open in calendar app').closest('a')?.getAttribute('href')).toBe(
			'webcal://kammer.example.com/calendar/user/tok.ics'
		);
	});

	it('shows a neutral error and reveals no URL when the fetch fails', async () => {
		const load = vi.fn().mockRejectedValue(new Error('nope'));
		render(CalendarSubscribe, { props: { load, label: 'Subscribe', id: 'cal' } });

		await fireEvent.click(document.querySelector('#cal-reveal')!);

		await waitFor(() => expect(screen.getByText(/try again/i)).toBeTruthy());
		expect(document.querySelector('#cal')).toBeNull();
	});
});
