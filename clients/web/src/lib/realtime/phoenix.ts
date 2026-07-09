import { Socket } from 'phoenix';
import type { CreateTransport, Transport, TransportChannel, TransportClose } from './transport.js';

/**
 * The production transport: a real Phoenix `Socket` at `<baseUrl>/api/socket`
 * (KammerWeb.Api.UserSocket), authenticated with the device token as the
 * `token` connect param.
 *
 * Reconnect/backoff is owned by the manager (manager.ts), not Phoenix — a
 * fresh `Socket` is built per `connect()` and Phoenix's own reconnect timer
 * is stopped the moment a socket closes, so exactly one backoff clock runs
 * and it's the testable one. WebSocket close code 1008 (policy violation) is
 * mapped to an auth failure; other closes are treated as transient. (The
 * server currently rejects a revoked token at the WS handshake, which most
 * browsers report as 1006 — indistinguishable from a network drop — so the
 * primary auth-failure signal is the manager's `noteAuthFailure()`, driven by
 * the REST layer's #159 `auth` kind. This code path is the forward-compatible
 * hook for an explicit policy close.)
 */
class PhoenixTransport implements Transport {
	readonly #endpoint: string;
	readonly #token: string;
	readonly #openCallbacks: (() => void)[] = [];
	readonly #closeCallbacks: ((info: TransportClose) => void)[] = [];
	readonly #errorCallbacks: ((error: unknown) => void)[] = [];
	#socket: Socket | null = null;

	constructor(baseUrl: string, deviceToken: string) {
		// baseUrl may carry a trailing slash from user entry; the Socket
		// endpoint must not double it.
		this.#endpoint = `${baseUrl.replace(/\/$/, '')}/api/socket`;
		this.#token = deviceToken;
	}

	connect(): void {
		const socket = new Socket(this.#endpoint, { params: { token: this.#token } });
		let closed = false;

		socket.onOpen(() => {
			for (const callback of this.#openCallbacks) callback();
		});
		socket.onError((error: unknown) => {
			for (const callback of this.#errorCallbacks) callback(error);
		});
		socket.onClose((event: { code?: number } | undefined) => {
			if (closed) return;
			closed = true;
			// Halt Phoenix's built-in reconnect timers so the manager's
			// backoff is the sole driver of reconnection.
			socket.disconnect();
			const code = event?.code;
			for (const callback of this.#closeCallbacks) {
				callback({ code, unauthorized: code === 1008 });
			}
		});

		this.#socket = socket;
		socket.connect();
	}

	disconnect(): void {
		this.#socket?.disconnect();
		this.#socket = null;
	}

	channel(topic: string): TransportChannel {
		const socket = this.#socket;
		if (!socket) {
			throw new Error('Transport.channel called before connect');
		}
		// Phoenix's `Channel` push and `on` already match TransportChannel's
		// shape, so this wrapper is only a typed narrowing.
		const channel = socket.channel(topic, {});
		return {
			join: () => channel.join(),
			on: (event, callback) => {
				channel.on(event, callback);
			},
			leave: () => {
				channel.leave();
			}
		};
	}

	onOpen(callback: () => void): void {
		this.#openCallbacks.push(callback);
	}

	onClose(callback: (info: TransportClose) => void): void {
		this.#closeCallbacks.push(callback);
	}

	onError(callback: (error: unknown) => void): void {
		this.#errorCallbacks.push(callback);
	}
}

export const createPhoenixTransport: CreateTransport = (baseUrl, deviceToken) =>
	new PhoenixTransport(baseUrl, deviceToken);
