/**
 * The seam between the socket manager and Phoenix Channels. The manager
 * (manager.ts) depends only on these interfaces, never on `phoenix`
 * directly, so tests inject a fake transport and the reconnect/backoff and
 * channel-join logic can be exercised without a real WebSocket.
 *
 * One transport wraps one Phoenix `Socket` (one per added instance, ADR
 * 0001 / #173), authenticated with that instance's device token as the
 * `token` connect param — the same token the REST Bearer header carries.
 */

/** A single join attempt on a channel — mirrors Phoenix's push receiver. */
export interface TransportJoin {
	receive(status: 'ok' | 'error' | 'timeout', callback: (response: unknown) => void): TransportJoin;
}

/** A subscribed channel — mirrors the slice of Phoenix's `Channel` we use. */
export interface TransportChannel {
	join(): TransportJoin;
	on(event: string, callback: (payload: unknown) => void): void;
	leave(): void;
}

/** Why a socket closed — `unauthorized` stops reconnection (re-sign-in needed). */
export interface TransportClose {
	/** WebSocket close code, when the transport can supply one. */
	code?: number;
	/** The device token was rejected — a transient reconnect won't help. */
	unauthorized?: boolean;
}

export interface Transport {
	connect(): void;
	disconnect(): void;
	channel(topic: string): TransportChannel;
	onOpen(callback: () => void): void;
	onClose(callback: (info: TransportClose) => void): void;
	onError(callback: (error: unknown) => void): void;
}

/** Builds a transport for an instance base URL + device token. */
export type CreateTransport = (baseUrl: string, deviceToken: string) => Transport;
