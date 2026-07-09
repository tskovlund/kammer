/**
 * One added Kammer instance (ADR 0001): the client is a session-holder,
 * not a proxy — each instance's device token lives only in this client,
 * never touching a Kammer server other than the one it authenticates to.
 */
export interface Instance {
	id: string;
	baseUrl: string;
	instanceName: string;
	deviceToken: string;
	user: {
		id: string;
		email: string;
		displayName: string | null;
	};
	addedAt: string;
}
