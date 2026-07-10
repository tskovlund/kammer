import { describe, expect, it } from 'vitest';
import { resolveNotificationPath } from './notification-routing.js';
import type { Instance } from '$lib/instances/types.js';

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

describe('resolveNotificationPath', () => {
	it('resolves a group link to the instance-scoped group route', () => {
		const instance = fixture();
		const url = 'https://kammer.example.com/c/tagekammeret/g/friday-bar';

		expect(resolveNotificationPath(url, [instance])).toBe(
			'/i/instance-1/c/tagekammeret/g/friday-bar'
		);
	});

	it('resolves an event link to the instance-scoped event route (events -> e)', () => {
		const instance = fixture();
		const url = 'https://kammer.example.com/c/tagekammeret/events/abc-123';

		expect(resolveNotificationPath(url, [instance])).toBe('/i/instance-1/c/tagekammeret/e/abc-123');
	});

	it('picks the instance whose baseUrl origin matches the link', () => {
		const home = fixture({ id: 'home', baseUrl: 'https://home.example.com' });
		const away = fixture({ id: 'away', baseUrl: 'https://away.example.com' });
		const url = 'https://away.example.com/c/some-group/g/chores';

		expect(resolveNotificationPath(url, [home, away])).toBe('/i/away/c/some-group/g/chores');
	});

	it('returns null when no added instance matches the link origin', () => {
		const url = 'https://gone.example.com/c/tagekammeret/g/friday-bar';

		expect(resolveNotificationPath(url, [fixture()])).toBeNull();
	});

	it('returns null for an unrecognized path shape', () => {
		const instance = fixture();

		expect(resolveNotificationPath('https://kammer.example.com/settings', [instance])).toBeNull();
	});

	it('returns null for a malformed URL', () => {
		expect(resolveNotificationPath('not a url', [fixture()])).toBeNull();
	});
});
