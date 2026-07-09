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

	it('persists a versioned envelope to the underlying localStorage key', () => {
		instanceStore.add(fixture());
		const raw = localStorage.getItem('kammer:instances');
		expect(raw).not.toBeNull();
		expect(JSON.parse(raw!)).toEqual({ version: 1, instances: [fixture()] });
	});

	describe('migration and validation on read (issue #158)', () => {
		it('reads a v0 bare-array payload written before the envelope existed', () => {
			localStorage.setItem('kammer:instances', JSON.stringify([fixture()]));
			expect(instanceStore.list()).toEqual([fixture()]);
		});

		it('rewrites a v0 payload as a v1 envelope on the next write', () => {
			localStorage.setItem(
				'kammer:instances',
				JSON.stringify([fixture({ id: 'a', baseUrl: 'https://one.example.com' })])
			);
			instanceStore.add(fixture({ id: 'b', baseUrl: 'https://two.example.com' }));
			expect(JSON.parse(localStorage.getItem('kammer:instances')!)).toEqual({
				version: 1,
				instances: [
					fixture({ id: 'a', baseUrl: 'https://one.example.com' }),
					fixture({ id: 'b', baseUrl: 'https://two.example.com' })
				]
			});
		});

		it('drops malformed elements instead of returning them', () => {
			const valid = fixture();
			localStorage.setItem(
				'kammer:instances',
				JSON.stringify({
					version: 1,
					instances: [
						valid,
						null,
						'not-an-instance',
						{ id: 'missing-everything-else' },
						{ ...valid, deviceToken: 42 },
						{ ...valid, user: { id: 'u', email: null, displayName: null } }
					]
				})
			);
			expect(instanceStore.list()).toEqual([valid]);
		});

		it('accepts a null displayName as valid', () => {
			const instance = fixture({
				user: { id: 'user-1', email: 'a@example.com', displayName: null }
			});
			localStorage.setItem(
				'kammer:instances',
				JSON.stringify({ version: 1, instances: [instance] })
			);
			expect(instanceStore.list()).toEqual([instance]);
		});

		it('returns empty for an envelope with an unknown version', () => {
			localStorage.setItem(
				'kammer:instances',
				JSON.stringify({ version: 999, instances: [fixture()] })
			);
			expect(instanceStore.list()).toEqual([]);
		});

		it('returns empty for non-JSON garbage', () => {
			localStorage.setItem('kammer:instances', 'not json at all');
			expect(instanceStore.list()).toEqual([]);
		});

		it('returns empty for JSON that is neither an array nor an envelope', () => {
			localStorage.setItem('kammer:instances', JSON.stringify({ some: 'object' }));
			expect(instanceStore.list()).toEqual([]);
		});
	});
});
