import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { InstanceSocketManager, type SocketStatus } from './manager';
import type { Transport, TransportChannel, TransportClose, TransportJoin } from './transport';
import type { Instance } from '$lib/instances/types';

function instance(overrides: Partial<Instance> = {}): Instance {
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

/** A joined channel on the fake transport — records events and join calls. */
class FakeChannel implements TransportChannel {
	readonly topic: string;
	readonly handlers = new Map<string, (payload: unknown) => void>();
	joinCount = 0;
	leaveCount = 0;

	constructor(topic: string) {
		this.topic = topic;
	}

	join(): TransportJoin {
		this.joinCount += 1;
		// The manager doesn't depend on join replies today, so a no-op
		// chainable receiver is enough.
		const join: TransportJoin = { receive: () => join };
		return join;
	}

	on(event: string, callback: (payload: unknown) => void): void {
		this.handlers.set(event, callback);
	}

	leave(): void {
		this.leaveCount += 1;
	}

	emit(event: string, payload: unknown): void {
		this.handlers.get(event)?.(payload);
	}
}

/**
 * A hand-driven transport: the test decides when the socket opens, closes,
 * or errors, and can reach any channel the manager created to push events.
 * One `FakeTransport` is created per `createTransport` call (per connect
 * attempt), mirroring the Phoenix adapter's fresh-socket-per-connect model.
 */
class FakeTransport implements Transport {
	static instances: FakeTransport[] = [];
	/** When true, `disconnect()` fires the close callback synchronously, like
	 * the real Phoenix transport — used to exercise teardown re-entrancy. */
	static closeOnDisconnect = false;
	readonly channels: FakeChannel[] = [];
	connectCount = 0;
	disconnectCount = 0;
	#open?: () => void;
	#close?: (info: TransportClose) => void;
	#error?: (error: unknown) => void;

	constructor() {
		FakeTransport.instances.push(this);
	}

	static latest(): FakeTransport {
		const transport = FakeTransport.instances.at(-1);
		if (!transport) throw new Error('no transport created yet');
		return transport;
	}

	static reset(): void {
		FakeTransport.instances = [];
		FakeTransport.closeOnDisconnect = false;
	}

	connect(): void {
		this.connectCount += 1;
	}

	disconnect(): void {
		this.disconnectCount += 1;
		if (FakeTransport.closeOnDisconnect) this.#close?.({});
	}

	channel(topic: string): TransportChannel {
		const channel = new FakeChannel(topic);
		this.channels.push(channel);
		return channel;
	}

	onOpen(callback: () => void): void {
		this.#open = callback;
	}
	onClose(callback: (info: TransportClose) => void): void {
		this.#close = callback;
	}
	onError(callback: (error: unknown) => void): void {
		this.#error = callback;
	}

	// Test drivers:
	fireOpen(): void {
		this.#open?.();
	}
	fireClose(info: TransportClose = {}): void {
		this.#close?.(info);
	}
	fireError(error: unknown = new Error('boom')): void {
		this.#error?.(error);
	}
	channelFor(topic: string): FakeChannel {
		const channel = this.channels.find((candidate) => candidate.topic === topic);
		if (!channel) throw new Error(`no channel joined for ${topic}`);
		return channel;
	}
}

function manager(options: { baseBackoffMs?: number; maxBackoffMs?: number } = {}) {
	return new InstanceSocketManager(instance(), {
		createTransport: () => new FakeTransport(),
		baseBackoffMs: options.baseBackoffMs ?? 1_000,
		maxBackoffMs: options.maxBackoffMs ?? 30_000
	});
}

describe('InstanceSocketManager', () => {
	beforeEach(() => {
		FakeTransport.reset();
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it('connects and reports open, then joins subscriptions on open', () => {
		const socket = manager();
		const statuses: SocketStatus[] = [];
		socket.onStatusChange((status) => statuses.push(status));

		socket.subscribeFeed('group-9', {});
		socket.connect();
		expect(FakeTransport.latest().connectCount).toBe(1);
		expect(statuses).toEqual(['connecting']);

		FakeTransport.latest().fireOpen();

		expect(socket.status).toBe('open');
		expect(statuses).toEqual(['connecting', 'open']);
		expect(FakeTransport.latest().channelFor('feed:group:group-9').joinCount).toBe(1);
	});

	it('routes feed events to the matching handlers with parsed payloads', () => {
		const socket = manager();
		const created: string[] = [];
		const deleted: string[] = [];
		socket.subscribeFeed('g1', {
			onPostCreated: (post) => created.push(post.id),
			onPostDeleted: (id) => deleted.push(id)
		});
		socket.connect();
		FakeTransport.latest().fireOpen();

		const channel = FakeTransport.latest().channelFor('feed:group:g1');
		channel.emit('post_created', { id: 'post-1' });
		channel.emit('post_deleted', { id: 'post-2' });

		expect(created).toEqual(['post-1']);
		expect(deleted).toEqual(['post-2']);
	});

	it('joins a subscription added after the socket is already open', () => {
		const socket = manager();
		socket.connect();
		FakeTransport.latest().fireOpen();

		socket.subscribeNotifications('user-1', {});

		expect(FakeTransport.latest().channelFor('notifications:user:user-1').joinCount).toBe(1);
	});

	it('leaves a channel when its subscription is cancelled', () => {
		const socket = manager();
		const unsubscribe = socket.subscribeFeed('g1', {});
		socket.connect();
		FakeTransport.latest().fireOpen();
		const channel = FakeTransport.latest().channelFor('feed:group:g1');

		unsubscribe();

		expect(channel.leaveCount).toBe(1);
	});

	it('reconnects with exponential backoff after an unclean close', () => {
		const socket = manager({ baseBackoffMs: 1_000, maxBackoffMs: 30_000 });
		socket.connect();
		FakeTransport.latest().fireOpen();

		// First drop: reconnect after base delay.
		FakeTransport.latest().fireClose();
		expect(socket.status).toBe('reconnecting');
		vi.advanceTimersByTime(999);
		expect(FakeTransport.instances).toHaveLength(1);
		vi.advanceTimersByTime(1);
		expect(FakeTransport.instances).toHaveLength(2);

		// Second consecutive drop (no successful open between): delay doubles.
		FakeTransport.latest().fireClose();
		vi.advanceTimersByTime(1_999);
		expect(FakeTransport.instances).toHaveLength(2);
		vi.advanceTimersByTime(1);
		expect(FakeTransport.instances).toHaveLength(3);
	});

	it('resets the backoff after a successful reconnection', () => {
		const socket = manager({ baseBackoffMs: 1_000 });
		socket.connect();
		FakeTransport.latest().fireOpen();

		FakeTransport.latest().fireClose();
		vi.advanceTimersByTime(1_000);
		expect(FakeTransport.instances).toHaveLength(2);
		FakeTransport.latest().fireOpen(); // success resets attempts

		FakeTransport.latest().fireClose();
		// Back to the base delay, not the doubled one.
		vi.advanceTimersByTime(1_000);
		expect(FakeTransport.instances).toHaveLength(3);
	});

	it('caps the backoff at maxBackoffMs', () => {
		const socket = manager({ baseBackoffMs: 1_000, maxBackoffMs: 4_000 });
		socket.connect();
		FakeTransport.latest().fireOpen();

		// Drop repeatedly without a successful open: 1s, 2s, 4s, then capped 4s.
		for (const expected of [1_000, 2_000, 4_000, 4_000]) {
			FakeTransport.latest().fireClose();
			vi.advanceTimersByTime(expected - 1);
			const before = FakeTransport.instances.length;
			vi.advanceTimersByTime(1);
			expect(FakeTransport.instances.length).toBe(before + 1);
		}
	});

	it('surfaces an unauthorized close and stops reconnecting', () => {
		const socket = manager();
		const statuses: SocketStatus[] = [];
		socket.onStatusChange((status) => statuses.push(status));
		socket.connect();
		FakeTransport.latest().fireOpen();

		FakeTransport.latest().fireClose({ code: 1008, unauthorized: true });

		expect(socket.status).toBe('unauthorized');
		expect(statuses.at(-1)).toBe('unauthorized');
		vi.advanceTimersByTime(60_000);
		// No reconnect attempt scheduled.
		expect(FakeTransport.instances).toHaveLength(1);
	});

	it('surfaces a REST-driven auth failure via noteAuthFailure', () => {
		const socket = manager();
		socket.connect();
		FakeTransport.latest().fireOpen();

		socket.noteAuthFailure();

		expect(socket.status).toBe('unauthorized');
		expect(FakeTransport.latest().disconnectCount).toBe(1);
		vi.advanceTimersByTime(60_000);
		expect(FakeTransport.instances).toHaveLength(1);
	});

	it('reconnecting after an auth failure clears the unauthorized state', () => {
		const socket = manager();
		socket.connect();
		FakeTransport.latest().fireOpen();
		socket.noteAuthFailure();
		expect(socket.status).toBe('unauthorized');

		socket.connect();

		expect(socket.status).toBe('connecting');
		expect(FakeTransport.instances).toHaveLength(2);
	});

	it('does not reconnect after an explicit disconnect', () => {
		const socket = manager();
		socket.connect();
		FakeTransport.latest().fireOpen();

		socket.disconnect();
		expect(socket.status).toBe('closed');
		expect(FakeTransport.latest().disconnectCount).toBe(1);

		// A late close from the torn-down transport must not schedule a retry.
		FakeTransport.latest().fireClose();
		vi.advanceTimersByTime(60_000);
		expect(FakeTransport.instances).toHaveLength(1);
	});

	it('does not flap when connect() tears down a still-open transport that closes synchronously', () => {
		// Phoenix fires onClose synchronously from disconnect(); tearing down a
		// live socket (e.g. the Home retry button calling reconnectInstance while
		// the socket is up) must not re-enter close handling and schedule a
		// spurious reconnect against the freshly opened transport.
		FakeTransport.closeOnDisconnect = true;
		const socket = manager({ baseBackoffMs: 1_000 });
		socket.connect();
		FakeTransport.latest().fireOpen();
		expect(socket.status).toBe('open');
		expect(FakeTransport.instances).toHaveLength(1);

		socket.connect(); // re-connect while open
		expect(FakeTransport.instances).toHaveLength(2); // exactly one new transport
		FakeTransport.latest().fireOpen();
		expect(socket.status).toBe('open');

		// No phantom reconnect timer fires to tear the fresh transport down.
		vi.advanceTimersByTime(60_000);
		expect(FakeTransport.instances).toHaveLength(2);
		expect(socket.status).toBe('open');
	});

	it('cancels a pending reconnect timer when reconnected explicitly', () => {
		const socket = manager({ baseBackoffMs: 1_000 });
		socket.connect();
		FakeTransport.latest().fireOpen();
		FakeTransport.latest().fireClose(); // schedules a reconnect
		expect(socket.status).toBe('reconnecting');

		socket.connect(); // explicit reconnect before the timer fires
		expect(FakeTransport.instances).toHaveLength(2);
		FakeTransport.latest().fireOpen();

		// The previously-armed timer must not fire and open a third transport.
		vi.advanceTimersByTime(60_000);
		expect(FakeTransport.instances).toHaveLength(2);
	});

	it('re-joins subscriptions on each reconnection', () => {
		const socket = manager({ baseBackoffMs: 1_000 });
		socket.subscribeFeed('g1', {});
		socket.connect();
		FakeTransport.latest().fireOpen();
		expect(FakeTransport.latest().channelFor('feed:group:g1').joinCount).toBe(1);

		FakeTransport.latest().fireClose();
		vi.advanceTimersByTime(1_000);
		FakeTransport.latest().fireOpen();

		// The fresh transport joined the same subscription.
		expect(FakeTransport.instances).toHaveLength(2);
		expect(FakeTransport.latest().channelFor('feed:group:g1').joinCount).toBe(1);
	});
});
