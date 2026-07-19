import { afterEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, waitFor } from '@testing-library/svelte';

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
		expect(document.querySelector('#cal-open')?.getAttribute('href')).toBe(
			'webcal://kammer.example.com/calendar/user/tok.ics'
		);
	});

	it('shows a neutral error and reveals no URL when the fetch fails', async () => {
		const load = vi.fn().mockRejectedValue(new Error('nope'));
		render(CalendarSubscribe, { props: { load, label: 'Subscribe', id: 'cal' } });

		const reveal = document.querySelector('#cal-reveal')!;
		await fireEvent.click(reveal);

		// The reveal control flips to the error label; no URL is revealed.
		await waitFor(() =>
			expect(reveal.textContent?.trim()).toBe("Couldn't load the link. Try again.")
		);
		expect(document.querySelector('#cal')).toBeNull();
	});

	it('resets the link, swapping in the new URL and confirming (#291)', async () => {
		const load = vi.fn().mockResolvedValue({
			token: 'old',
			url: 'https://kammer.example.com/calendar/user/old.ics'
		});
		const reset = vi.fn().mockResolvedValue({
			token: 'new',
			url: 'https://kammer.example.com/calendar/user/new.ics'
		});
		render(CalendarSubscribe, { props: { load, reset, label: 'Subscribe', id: 'cal' } });

		await fireEvent.click(document.querySelector('#cal-reveal')!);
		await waitFor(() => expect(document.querySelector('#cal')).toBeTruthy());

		await fireEvent.click(document.querySelector('#cal-reset')!);
		await waitFor(() => expect(reset).toHaveBeenCalledOnce());

		// The visible link and the webcal open link both swap to the new token.
		expect(document.querySelector('#cal')?.textContent).toBe(
			'https://kammer.example.com/calendar/user/new.ics'
		);
		expect(document.querySelector('#cal-open')?.getAttribute('href')).toBe(
			'webcal://kammer.example.com/calendar/user/new.ics'
		);
		expect(document.querySelector('#cal-reset-status')?.textContent?.trim()).toBe(
			'Link reset — your old calendar URL no longer works. Paste the new one into your calendar app.'
		);
	});

	it('keeps the current link and shows an error when a reset fails (#291)', async () => {
		const load = vi.fn().mockResolvedValue({
			token: 'old',
			url: 'https://kammer.example.com/calendar/user/old.ics'
		});
		const reset = vi.fn().mockRejectedValue(new Error('nope'));
		render(CalendarSubscribe, { props: { load, reset, label: 'Subscribe', id: 'cal' } });

		await fireEvent.click(document.querySelector('#cal-reveal')!);
		await waitFor(() => expect(document.querySelector('#cal')).toBeTruthy());

		await fireEvent.click(document.querySelector('#cal-reset')!);
		await waitFor(() =>
			expect(document.querySelector('#cal-reset-status')?.textContent?.trim()).toBe(
				"Couldn't reset the link. Try again."
			)
		);

		// The still-valid current link is preserved, not blanked.
		expect(document.querySelector('#cal')?.textContent).toBe(
			'https://kammer.example.com/calendar/user/old.ics'
		);
	});

	it('offers no reset control when no reset handler is given (group calendars)', async () => {
		const load = vi.fn().mockResolvedValue({
			token: 'tok',
			url: 'https://kammer.example.com/calendar/group/tok.ics'
		});
		render(CalendarSubscribe, { props: { load, label: 'Subscribe', id: 'cal' } });

		await fireEvent.click(document.querySelector('#cal-reveal')!);
		await waitFor(() => expect(document.querySelector('#cal')).toBeTruthy());

		expect(document.querySelector('#cal-reset')).toBeNull();
	});
});
