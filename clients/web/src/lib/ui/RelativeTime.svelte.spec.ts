import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { flushSync } from 'svelte';
import RelativeTime from './RelativeTime.svelte';

describe('RelativeTime', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-16T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		document.body.innerHTML = '';
	});

	// The component's reason to exist beyond `formatRelativeTime` (which
	// datetime.spec.ts covers): the rendered string keeps aging. A static
	// render fossilizes "2 minutes ago" forever on an installed PWA that
	// stays open for days (part of #270).
	it('keeps the relative time aging while mounted', () => {
		render(RelativeTime, { props: { datetime: '2026-07-16T11:58:00Z' } });
		expect(screen.getByText('2 minutes ago')).toBeTruthy();

		vi.advanceTimersByTime(60_000);
		flushSync();
		expect(screen.getByText('3 minutes ago')).toBeTruthy();
	});

	it('stops the shared ticker when the last subscriber unmounts', async () => {
		const { unmount } = render(RelativeTime, { props: { datetime: '2026-07-16T11:58:00Z' } });
		expect(vi.getTimerCount()).toBe(1);

		unmount();
		// createSubscriber tears down in a microtask after the effect dies.
		await Promise.resolve();
		expect(vi.getTimerCount()).toBe(0);
	});
});
