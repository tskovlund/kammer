import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '$lib/api/errors';
import type { TransportClose } from './transport';

// A fake Phoenix Socket that records its connect params and exposes lifecycle
// hooks, hoisted so the `phoenix` module mock can close over the registry.
const { sockets, FakeSocket } = vi.hoisted(() => {
	class FakeSocket {
		readonly endpoint: string;
		readonly params: { token: string };
		connected = false;
		disconnected = false;
		constructor(endpoint: string, opts: { params: { token: string } }) {
			this.endpoint = endpoint;
			this.params = opts.params;
			sockets.push(this);
		}
		onOpen() {}
		onError() {}
		onClose() {}
		connect() {
			this.connected = true;
		}
		disconnect() {
			this.disconnected = true;
		}
	}
	const sockets: FakeSocket[] = [];
	return { sockets, FakeSocket };
});

vi.mock('phoenix', () => ({ Socket: FakeSocket }));
vi.mock('./token.js', () => ({ fetchRealtimeToken: vi.fn() }));

import { createPhoenixTransport } from './phoenix';
import { fetchRealtimeToken } from './token.js';

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
	sockets.length = 0;
	vi.mocked(fetchRealtimeToken).mockReset();
});
afterEach(() => vi.restoreAllMocks());

describe('PhoenixTransport connect', () => {
	it('mints a fresh socket token and connects with it — the device token stays out of the socket', async () => {
		vi.mocked(fetchRealtimeToken).mockResolvedValueOnce('sock-token');
		const transport = createPhoenixTransport('https://k.example/', 'device-abc');

		transport.connect();
		await flush();

		expect(vi.mocked(fetchRealtimeToken)).toHaveBeenCalledWith('https://k.example/', 'device-abc');
		expect(sockets).toHaveLength(1);
		expect(sockets[0]?.endpoint).toBe('https://k.example/api/socket');
		expect(sockets[0]?.params).toEqual({ token: 'sock-token' });
		expect(sockets[0]?.connected).toBe(true);
	});

	it('closes as unauthorized when the mint fails with an auth error, transient otherwise', async () => {
		const transport = createPhoenixTransport('https://k.example', 'device-abc');
		const closes: TransportClose[] = [];
		transport.onClose((info) => closes.push(info));

		vi.mocked(fetchRealtimeToken).mockRejectedValueOnce(new ApiError('auth', 'gone', 401));
		transport.connect();
		await flush();

		vi.mocked(fetchRealtimeToken).mockRejectedValueOnce(new ApiError('network', 'offline', null));
		transport.connect();
		await flush();

		expect(sockets).toHaveLength(0);
		expect(closes).toEqual([{ unauthorized: true }, { unauthorized: false }]);
	});

	it('does not build a socket when a disconnect races the token fetch', async () => {
		let resolveFetch: (token: string) => void = () => {};
		vi.mocked(fetchRealtimeToken).mockReturnValueOnce(
			new Promise<string>((resolve) => {
				resolveFetch = resolve;
			})
		);
		const transport = createPhoenixTransport('https://k.example', 'device-abc');

		transport.connect();
		// Tear down while the token is still in flight, then let the fetch resolve.
		transport.disconnect();
		resolveFetch('sock-token');
		await flush();

		// The superseded connect must drop its token rather than revive the
		// torn-down transport.
		expect(sockets).toHaveLength(0);
	});
});
