import { Socket } from 'phoenix';
import { ApiError } from '$lib/api/errors.js';
import { fetchRealtimeToken } from './token.js';
import type { CreateTransport, Transport, TransportChannel, TransportClose } from './transport.js';

/**
 * The production transport: a real Phoenix `Socket` at `<baseUrl>/api/socket`
 * (KammerWeb.Api.UserSocket). It connects with a short-lived socket token
 * (issue #175) minted over REST from the device token in the Authorization
 * header — so the long-lived credential never rides in the socket URL. A
 * fresh token is fetched before each `connect()`, keeping the connect param
 * ~60s old at most.
 *
 * Reconnect/backoff is owned by the manager (manager.ts), not Phoenix — a
 * fresh `Socket` is built per `connect()` and Phoenix's own reconnect timer
 * is stopped the moment a socket closes, so exactly one backoff clock runs
 * and it's the testable one. A failure to mint the socket token is surfaced
 * as a close so the manager's backoff drives the retry; an `auth`/`forbidden`
 * mint failure closes as `unauthorized`, stopping reconnection. WebSocket
 * close code 1008 (policy violation) is likewise mapped to an auth failure;
 * other closes are transient.
 */
class PhoenixTransport implements Transport {
	readonly #baseUrl: string;
	readonly #endpoint: string;
	readonly #deviceToken: string;
	readonly #openCallbacks: (() => void)[] = [];
	readonly #closeCallbacks: ((info: TransportClose) => void)[] = [];
	readonly #errorCallbacks: ((error: unknown) => void)[] = [];
	#socket: Socket | null = null;
	// Bumped by every connect()/disconnect(), so an in-flight token fetch whose
	// connect was superseded (a reconnect) or cancelled (a disconnect) drops its
	// socket instead of reviving a torn-down transport.
	#generation = 0;

	constructor(baseUrl: string, deviceToken: string) {
		// baseUrl may carry a trailing slash from user entry; the Socket
		// endpoint must not double it.
		this.#baseUrl = baseUrl;
		this.#endpoint = `${baseUrl.replace(/\/$/, '')}/api/socket`;
		this.#deviceToken = deviceToken;
	}

	connect(): void {
		const generation = ++this.#generation;
		void this.#connect(generation);
	}

	async #connect(generation: number): Promise<void> {
		let token: string;
		try {
			token = await fetchRealtimeToken(this.#baseUrl, this.#deviceToken);
		} catch (cause) {
			// Superseded by a newer connect or a disconnect while we were minting.
			if (generation !== this.#generation) return;
			// Mirror a socket that never opened: a dead device token is an auth
			// failure (terminal); anything else is a transient close the manager
			// retries with backoff.
			const unauthorized =
				cause instanceof ApiError && (cause.kind === 'auth' || cause.kind === 'forbidden');
			for (const callback of this.#closeCallbacks) callback({ unauthorized });
			return;
		}

		// A disconnect (or a fresh connect) landed while minting — don't revive.
		if (generation !== this.#generation) return;

		const socket = new Socket(this.#endpoint, { params: { token } });
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
		// Invalidate any in-flight token fetch so its socket is never built.
		this.#generation++;
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
