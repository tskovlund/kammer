/**
 * Public surface of the realtime layer (ADR 0014, #173). One socket per
 * added instance, authenticated with that instance's device token — never a
 * merged connection. The transport (Phoenix) sits behind an interface so the
 * manager's reconnect/backoff and channel wiring stay testable with a fake.
 */
export { InstanceSocketManager } from './manager.js';
export type {
	SocketStatus,
	FeedHandlers,
	NotificationHandlers,
	SocketManagerOptions
} from './manager.js';
export type {
	Transport,
	TransportChannel,
	TransportJoin,
	TransportClose,
	CreateTransport
} from './transport.js';
export { createPhoenixTransport } from './phoenix.js';
