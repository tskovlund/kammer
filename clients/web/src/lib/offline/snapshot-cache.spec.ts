import { beforeEach, describe, expect, it, vi } from 'vitest';
import { loadSnapshot, saveSnapshot } from './snapshot-cache.js';
import { fakeLocalStorage } from '$lib/instances/test-support.js';

beforeEach(() => vi.stubGlobal('localStorage', fakeLocalStorage()));

describe('snapshot cache', () => {
	it('returns null when nothing has been saved for a key', () => {
		expect(loadSnapshot('home')).toBeNull();
	});

	it('round-trips the saved data', () => {
		saveSnapshot('home', { posts: ['a', 'b'] });

		expect(loadSnapshot<{ posts: string[] }>('home')?.data).toEqual({ posts: ['a', 'b'] });
	});

	it('stamps the snapshot with a parseable save time', () => {
		saveSnapshot('events', []);

		const snapshot = loadSnapshot('events');
		expect(snapshot?.savedAt).toBeTruthy();
		expect(Number.isNaN(Date.parse(snapshot!.savedAt))).toBe(false);
	});

	it('keeps snapshots for different keys independent', () => {
		saveSnapshot('home', { view: 'home' });
		saveSnapshot('events', { view: 'events' });

		expect(loadSnapshot<{ view: string }>('home')?.data).toEqual({ view: 'home' });
		expect(loadSnapshot<{ view: string }>('events')?.data).toEqual({ view: 'events' });
	});

	it('treats unparseable stored data as no snapshot rather than throwing', () => {
		localStorage.setItem('kammer:snapshot:home', 'not json');

		expect(loadSnapshot('home')).toBeNull();
	});

	it('ignores a snapshot from an unrecognized envelope version', () => {
		localStorage.setItem(
			'kammer:snapshot:home',
			JSON.stringify({ version: 2, savedAt: new Date().toISOString(), data: {} })
		);

		expect(loadSnapshot('home')).toBeNull();
	});
});
