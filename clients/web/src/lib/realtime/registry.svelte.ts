import type { Instance } from '$lib/instances/types.js';
import { InstanceSocketManager, type SocketStatus } from './manager.js';

/**
 * One long-lived socket per added instance, shared across every screen (the
 * group feed, Home's live updates, the notifications badge). Screens subscribe
 * to channels on mount and unsubscribe on unmount; the underlying connection
 * stays up so navigating between a community's groups doesn't churn the socket.
 *
 * Connection status is reactive so the shell can surface a per-instance
 * "reconnecting…" hint or a re-sign-in prompt when a token is revoked
 * (`unauthorized`) — the socket-side twin of the REST #159 failure kinds.
 */
// A plain object (not a reactive SvelteMap): this is memoization, not UI
// state — the reactive part is `statuses`, updated via onStatusChange.
const managers: Record<string, InstanceSocketManager> = {};
const statuses = $state<Record<string, SocketStatus>>({});

export function getSocket(instance: Instance): InstanceSocketManager {
	let manager = managers[instance.id];
	if (!manager) {
		manager = new InstanceSocketManager(instance);
		manager.onStatusChange((status) => {
			statuses[instance.id] = status;
		});
		managers[instance.id] = manager;
		manager.connect();
	}
	return manager;
}

/** Reactive connection status for an instance (`idle` until first use). */
export function socketStatus(instanceId: string): SocketStatus {
	return statuses[instanceId] ?? 'idle';
}

/**
 * Mark an instance's socket unauthorized after a REST 401 (the caller learns
 * the token was revoked over REST before the socket necessarily notices).
 */
export function noteInstanceAuthFailure(instance: Instance): void {
	getSocket(instance).noteAuthFailure();
}

/** Re-establish an instance's socket after the user re-authenticates it. */
export function reconnectInstance(instance: Instance): void {
	getSocket(instance).connect();
}

/** Tear down a socket (e.g. when an instance is removed). Test/teardown aid. */
export function dropSocket(instanceId: string): void {
	managers[instanceId]?.disconnect();
	delete managers[instanceId];
	delete statuses[instanceId];
}
