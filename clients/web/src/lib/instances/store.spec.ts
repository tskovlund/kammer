import { beforeEach, describe, expect, it, vi } from 'vitest';
import { instanceStore } from './store';
import { fakeLocalStorage } from './test-support';
import type { Instance } from './types';

function fixture(overrides: Partial<Instance> = {}): Instance {
	return {
		id: 'instance-1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'user-1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z',
		...overrides
	};
}

describe('instanceStore', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeLocalStorage());
		instanceStore.clear();
	});

	it('starts empty', () => {
		expect(instanceStore.list()).toEqual([]);
	});

	it('adds and lists instances', () => {
		instanceStore.add(fixture());
		expect(instanceStore.list()).toEqual([fixture()]);
	});

	it('replaces an instance with the same id instead of duplicating it', () => {
		instanceStore.add(fixture());
		instanceStore.add(fixture({ instanceName: 'Renamed' }));
		expect(instanceStore.list()).toHaveLength(1);
		expect(instanceStore.list()[0].instanceName).toBe('Renamed');
	});

	it('replaces an instance for the same (baseUrl, user) even with a new id — re-authenticating must not duplicate it', () => {
		instanceStore.add(fixture({ id: 'first-sign-in', deviceToken: 'old-token' }));
		instanceStore.add(fixture({ id: 'second-sign-in', deviceToken: 'new-token' }));
		const instances = instanceStore.list();
		expect(instances).toHaveLength(1);
		expect(instances[0].deviceToken).toBe('new-token');
	});

	it('keeps instances with different (baseUrl, user) as separate entries', () => {
		instanceStore.add(fixture({ id: 'a', baseUrl: 'https://one.example.com' }));
		instanceStore.add(fixture({ id: 'b', baseUrl: 'https://two.example.com' }));
		expect(instanceStore.list()).toHaveLength(2);
	});

	it('removes an instance by id', () => {
		instanceStore.add(fixture({ id: 'a', baseUrl: 'https://one.example.com' }));
		instanceStore.add(fixture({ id: 'b', baseUrl: 'https://two.example.com' }));
		instanceStore.remove('a');
		expect(instanceStore.list().map((instance) => instance.id)).toEqual(['b']);
	});

	it('get returns undefined for an unknown id', () => {
		expect(instanceStore.get('missing')).toBeUndefined();
	});

	it('persists to the underlying localStorage key, not just in-memory state', () => {
		instanceStore.add(fixture());
		const raw = localStorage.getItem('kammer:instances');
		expect(raw).not.toBeNull();
		expect(JSON.parse(raw!)).toEqual([fixture()]);
	});
});
