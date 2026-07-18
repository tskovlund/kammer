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
		vi.restoreAllMocks();
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

	it('shares one ticker and one visibility listener, and tears both down', async () => {
		const add = vi.spyOn(document, 'addEventListener');
		const remove = vi.spyOn(document, 'removeEventListener');

		const first = render(RelativeTime, { props: { datetime: '2026-07-16T11:58:00Z' } });
		const second = render(RelativeTime, { props: { datetime: '2026-07-16T11:59:00Z' } });
		// The design point of ui/now.ts: N timestamps, one interval and one
		// shared visibilitychange listener (#316) — not one per consumer.
		expect(vi.getTimerCount()).toBe(1);
		expect(add.mock.calls.filter(([type]) => type === 'visibilitychange')).toHaveLength(1);

		first.unmount();
		second.unmount();
		// createSubscriber tears down in a microtask after the effect dies.
		await Promise.resolve();
		expect(vi.getTimerCount()).toBe(0);
		// The listener is removed with the interval — no leak.
		expect(remove.mock.calls.filter(([type]) => type === 'visibilitychange')).toHaveLength(1);
	});

	// A backgrounded tab's interval is throttled or paused, so on wake the
	// on-screen time can be up to a minute stale until the next tick — the
	// visibilitychange snap closes that gap (#316).
	it('snaps fresh the instant the tab foregrounds, without waiting for a tick', () => {
		render(RelativeTime, { props: { datetime: '2026-07-16T11:58:00Z' } });
		expect(screen.getByText('2 minutes ago')).toBeTruthy();

		// Time moved on while backgrounded, but the interval never fired.
		vi.setSystemTime(new Date('2026-07-16T12:05:00Z'));
		document.dispatchEvent(new Event('visibilitychange'));
		flushSync();

		expect(screen.getByText('7 minutes ago')).toBeTruthy();
	});
});
