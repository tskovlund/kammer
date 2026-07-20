import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { clearPendingInvite, rememberPendingInvite, takePendingInvite } from './pending.js';

const KEY = 'kammer:pending-invite';

function fakeStorage(): Storage {
	const store = new Map<string, string>();
	return {
		getItem: (key: string) => store.get(key) ?? null,
		setItem: (key: string, value: string) => void store.set(key, value),
		removeItem: (key: string) => void store.delete(key),
		clear: () => store.clear(),
		key: () => null,
		get length() {
			return store.size;
		}
	};
}

describe('pending invite carry', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeStorage());
	});

	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it('round-trips a token exactly once', () => {
		rememberPendingInvite('AbC-123_x');
		expect(takePendingInvite()).toBe('AbC-123_x');
		expect(takePendingInvite()).toBeNull();
	});

	it('refuses to WRITE a malformed token — nothing reaches storage', () => {
		rememberPendingInvite('not a token!/../');
		expect(localStorage.getItem(KEY)).toBeNull();
	});

	it('drops a tampered stored value instead of returning it', () => {
		localStorage.setItem(
			KEY,
			JSON.stringify({ token: 'javascript:alert(1)', expiresAt: Date.now() + 1000 })
		);
		expect(takePendingInvite()).toBeNull();
		localStorage.setItem(KEY, 'not json');
		expect(takePendingInvite()).toBeNull();
	});

	it("a matching take consumes only its own token — another invite's entry survives", () => {
		rememberPendingInvite('invite-A');
		expect(takePendingInvite('invite-B')).toBeNull();
		expect(takePendingInvite('invite-A')).toBe('invite-A');
		expect(takePendingInvite()).toBeNull();
	});

	it('treats an expired entry as absent — no ambush joins days later', () => {
		localStorage.setItem(KEY, JSON.stringify({ token: 'AbC-123_x', expiresAt: Date.now() - 1 }));
		expect(takePendingInvite()).toBeNull();
	});

	it('clearPendingInvite drops a stored token without consuming it as a join (#369)', () => {
		rememberPendingInvite('AbC-123_x');
		clearPendingInvite();
		// Gone for the next signer-in on a shared device.
		expect(localStorage.getItem(KEY)).toBeNull();
	});
});
