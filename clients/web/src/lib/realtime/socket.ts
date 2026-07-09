import type { Instance } from '$lib/instances/types.js';

/**
 * The seam where Phoenix Channels will plug in — types only for now, so
 * the data layer's shape is settled before any socket code exists. Like
 * the REST client (client.ts), realtime is per instance: one socket per
 * added instance, authenticated with that instance's device token, never
 * a merged connection.
 */
export interface InstanceSocket {
	readonly instance: Instance;
	connect(): void;
	disconnect(): void;
	/** Subscribe to a server-pushed event; returns an unsubscribe function. */
	on(event: string, handler: (payload: unknown) => void): () => void;
}

export type CreateInstanceSocket = (instance: Instance) => InstanceSocket;
