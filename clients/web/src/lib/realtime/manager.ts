import type { components } from '$lib/api/schema.js';
import type { Instance } from '$lib/instances/types.js';
import { createPhoenixTransport } from './phoenix.js';
import type { CreateTransport, Transport, TransportChannel } from './transport.js';

type Post = components['schemas']['Post'];
type Notification = components['schemas']['Notification'];

/**
 * Connection status of one instance's socket. `unauthorized` is terminal
 * until the caller re-authenticates the instance — it stops reconnection so
 * a revoked device token doesn't spin forever, and lets the UI prompt a
 * per-instance re-sign-in (the #159 `auth` failure kind, over the socket).
 */
export type SocketStatus =
	'idle' | 'connecting' | 'open' | 'reconnecting' | 'unauthorized' | 'closed';

export interface FeedHandlers {
	onPostCreated?: (post: Post) => void;
	onPostUpdated?: (post: Post) => void;
	onPostDeleted?: (postId: string) => void;
}

export interface NotificationHandlers {
	onNotificationCreated?: (notification: Notification) => void;
}

export interface SocketManagerOptions {
	createTransport?: CreateTransport;
	/** First reconnect delay; doubles each attempt up to `maxBackoffMs`. */
	baseBackoffMs?: number;
	maxBackoffMs?: number;
	/** Injectable timers so tests can drive backoff deterministically. */
	setTimer?: (callback: () => void, ms: number) => number;
	clearTimer?: (handle: number) => void;
}

interface Subscription {
	topic: string;
	/** Wires event handlers onto a freshly created channel, then joins. */
	activate: (channel: TransportChannel) => void;
	/** The live channel for this subscription while the socket is open. */
	channel: TransportChannel | null;
}

const DEFAULT_BASE_BACKOFF_MS = 1_000;
const DEFAULT_MAX_BACKOFF_MS = 30_000;

/**
 * One socket per added instance (ADR 0001 / #173): joins `feed:group:<id>`
 * and `notifications:user:<id>` channels on demand, reconnects with
 * exponential backoff, and surfaces auth failure so a revoked token can be
 * re-authenticated per instance rather than silently retried.
 *
 * The transport (Phoenix in production, a fake in tests) is injected, and
 * all reconnect/backoff logic lives here rather than in Phoenix — so the
 * behaviour is exercised end to end against the fake transport.
 */
export class InstanceSocketManager {
	readonly instance: Instance;
	readonly #createTransport: CreateTransport;
	readonly #baseBackoffMs: number;
	readonly #maxBackoffMs: number;
	readonly #setTimer: (callback: () => void, ms: number) => number;
	readonly #clearTimer: (handle: number) => void;

	readonly #subscriptions: Subscription[] = [];
	readonly #statusListeners = new Set<(status: SocketStatus) => void>();

	#transport: Transport | null = null;
	#status: SocketStatus = 'idle';
	#attempts = 0;
	#reconnectTimer: number | null = null;
	/** True between `disconnect()`/auth-failure and the next `connect()`. */
	#stopped = false;
	/**
	 * Bumped on every teardown so a superseded transport's callbacks no-op.
	 * The real Phoenix transport fires `onClose` synchronously from its own
	 * `disconnect()`, so tearing down an *open* socket (e.g. a Home retry that
	 * calls `connect()` while the socket is live) would otherwise re-enter
	 * `#handleClose` and schedule a spurious reconnect against the fresh
	 * transport — a flap. Generation-gating the callbacks prevents it.
	 */
	#generation = 0;

	constructor(instance: Instance, options: SocketManagerOptions = {}) {
		this.instance = instance;
		this.#createTransport = options.createTransport ?? createPhoenixTransport;
		this.#baseBackoffMs = options.baseBackoffMs ?? DEFAULT_BASE_BACKOFF_MS;
		this.#maxBackoffMs = options.maxBackoffMs ?? DEFAULT_MAX_BACKOFF_MS;
		this.#setTimer = options.setTimer ?? ((callback, ms) => setTimeout(callback, ms) as never);
		this.#clearTimer = options.clearTimer ?? ((handle) => clearTimeout(handle));
	}

	get status(): SocketStatus {
		return this.#status;
	}

	onStatusChange(listener: (status: SocketStatus) => void): () => void {
		this.#statusListeners.add(listener);
		return () => this.#statusListeners.delete(listener);
	}

	connect(): void {
		this.#stopped = false;
		if (this.#status === 'unauthorized') this.#setStatus('idle');
		this.#openTransport();
	}

	disconnect(): void {
		this.#stopped = true;
		this.#cancelReconnect();
		this.#teardownTransport();
		this.#setStatus('closed');
	}

	/**
	 * Called by the REST layer when a request to this instance returns 401
	 * (the #159 `auth` kind): the device token is gone, so stop reconnecting
	 * and let the UI prompt a re-sign-in. `connect()` clears this.
	 */
	noteAuthFailure(): void {
		this.#stopped = true;
		this.#cancelReconnect();
		this.#teardownTransport();
		this.#setStatus('unauthorized');
	}

	/** Subscribe to a group's feed; returns an unsubscribe function. */
	subscribeFeed(groupId: string, handlers: FeedHandlers): () => void {
		return this.#addSubscription(`feed:group:${groupId}`, (channel) => {
			if (handlers.onPostCreated) {
				channel.on('post_created', (payload) => handlers.onPostCreated?.(payload as Post));
			}
			if (handlers.onPostUpdated) {
				channel.on('post_updated', (payload) => handlers.onPostUpdated?.(payload as Post));
			}
			if (handlers.onPostDeleted) {
				channel.on('post_deleted', (payload) =>
					handlers.onPostDeleted?.((payload as { id: string }).id)
				);
			}
			channel.join();
		});
	}

	/** Subscribe to the device owner's notification stream. */
	subscribeNotifications(userId: string, handlers: NotificationHandlers): () => void {
		return this.#addSubscription(`notifications:user:${userId}`, (channel) => {
			if (handlers.onNotificationCreated) {
				channel.on('notification_created', (payload) =>
					handlers.onNotificationCreated?.(payload as Notification)
				);
			}
			channel.join();
		});
	}

	#addSubscription(topic: string, activate: Subscription['activate']): () => void {
		const subscription: Subscription = { topic, activate, channel: null };
		this.#subscriptions.push(subscription);
		// Join immediately if the socket is already open; otherwise the next
		// open will activate it.
		if (this.#status === 'open' && this.#transport) {
			this.#activate(subscription);
		}
		return () => {
			const index = this.#subscriptions.indexOf(subscription);
			if (index !== -1) this.#subscriptions.splice(index, 1);
			subscription.channel?.leave();
			subscription.channel = null;
		};
	}

	#activate(subscription: Subscription): void {
		if (!this.#transport) return;
		const channel = this.#transport.channel(subscription.topic);
		subscription.channel = channel;
		subscription.activate(channel);
	}

	#openTransport(): void {
		this.#cancelReconnect();
		this.#teardownTransport();
		const transport = this.#createTransport(this.instance.baseUrl, this.instance.deviceToken);
		// Only the current generation's callbacks act; a close fired while
		// tearing this transport down later (bumping the generation) is ignored.
		const generation = this.#generation;
		transport.onOpen(() => {
			if (generation === this.#generation) this.#handleOpen();
		});
		transport.onClose((info) => {
			if (generation === this.#generation) this.#handleClose(info.unauthorized ?? false);
		});
		transport.onError(() => {
			/* errors are followed by a close; the close drives reconnection */
		});
		this.#transport = transport;
		this.#setStatus(this.#attempts === 0 ? 'connecting' : 'reconnecting');
		transport.connect();
	}

	#handleOpen(): void {
		this.#attempts = 0;
		this.#setStatus('open');
		for (const subscription of this.#subscriptions) {
			subscription.channel = null;
			this.#activate(subscription);
		}
	}

	#handleClose(unauthorized: boolean): void {
		for (const subscription of this.#subscriptions) subscription.channel = null;

		if (unauthorized) {
			this.noteAuthFailure();
			return;
		}
		if (this.#stopped) return;
		this.#scheduleReconnect();
	}

	#scheduleReconnect(): void {
		this.#cancelReconnect();
		const delay = Math.min(this.#baseBackoffMs * 2 ** this.#attempts, this.#maxBackoffMs);
		this.#attempts += 1;
		this.#setStatus('reconnecting');
		this.#reconnectTimer = this.#setTimer(() => {
			this.#reconnectTimer = null;
			if (this.#stopped) return;
			this.#openTransport();
		}, delay);
	}

	#cancelReconnect(): void {
		if (this.#reconnectTimer !== null) {
			this.#clearTimer(this.#reconnectTimer);
			this.#reconnectTimer = null;
		}
	}

	#teardownTransport(): void {
		// Retire the current generation before disconnecting: the real
		// transport's `disconnect()` can fire `onClose` synchronously, and that
		// callback must see a stale generation and no-op.
		this.#generation += 1;
		if (this.#transport) {
			this.#transport.disconnect();
			this.#transport = null;
		}
		for (const subscription of this.#subscriptions) subscription.channel = null;
	}

	#setStatus(status: SocketStatus): void {
		if (this.#status === status) return;
		this.#status = status;
		for (const listener of this.#statusListeners) listener(status);
	}
}
