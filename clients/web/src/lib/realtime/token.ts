import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';

/**
 * Mints a short-lived token for opening the realtime websocket (issue #175).
 * Authenticated with the device token in the `Authorization` header, so the
 * long-lived credential never rides in the socket URL where a fronting proxy
 * could log it. The socket transport fetches a fresh one before each connect;
 * it errors through the shared `ApiError`, so an `auth`/`forbidden` kind means
 * the device token is gone and reconnection should stop.
 */
export async function fetchRealtimeToken(baseUrl: string, deviceToken: string): Promise<string> {
	return guard(async () => {
		const { data, error, response } = await createApiClient(baseUrl, deviceToken).POST(
			'/api/v1/realtime/token',
			{}
		);
		if (error || !data) throw fail(error, response, 'Could not open the realtime connection.');
		return data.data.token;
	});
}
