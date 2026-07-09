import { createApiClient } from '$lib/api/client.js';
import type { components } from '$lib/api/schema.js';
import type { Instance } from './types.js';

type HomeResponse = components['schemas']['HomeResponse'];

export type MergedEvent = HomeResponse['upcoming_events'][number] & { instance: Instance };
export type MergedPost = HomeResponse['recent_activity'][number] & { instance: Instance };

/**
 * Why a `/home` call failed (issue #159) — the UI needs to react
 * differently: `auth` means the device token was revoked (offer
 * re-sign-in), `network` means the instance is unreachable (retry later),
 * `server` means it responded but errored.
 */
export type InstanceFailureKind = 'auth' | 'network' | 'server';

export interface FailedInstance {
	instance: Instance;
	kind: InstanceFailureKind;
}

export interface MergedHome {
	upcomingEvents: MergedEvent[];
	recentActivity: MergedPost[];
	/** Instances whose `/home` call failed — surfaced, not silently dropped. */
	failedInstances: FailedInstance[];
}

/**
 * Client-side merging of `GET /home` across every added instance (ADR
 * 0001) — there is no server-side aggregation, this client is a
 * session-holder, not a proxy. One instance being unreachable or having a
 * revoked token doesn't take down the merged view for the rest.
 */
const HOME_FETCH_TIMEOUT_MS = 10_000;

type InstanceResult =
	| { instance: Instance; data: HomeResponse }
	| { instance: Instance; data: null; kind: InstanceFailureKind };

export async function fetchMergedHome(instances: Instance[]): Promise<MergedHome> {
	const results: InstanceResult[] = await Promise.all(
		instances.map(async (instance): Promise<InstanceResult> => {
			const client = createApiClient(instance.baseUrl, instance.deviceToken);
			try {
				// A hung (not erroring, just non-responding) instance must not
				// block the merged view for every other instance forever.
				const { data, error, response } = await client.GET('/api/v1/home', {
					signal: AbortSignal.timeout(HOME_FETCH_TIMEOUT_MS)
				});
				if (error || !data) {
					return { instance, data: null, kind: response.status === 401 ? 'auth' : 'server' };
				}
				return { instance, data };
			} catch {
				// fetch() itself rejected: DNS failure, refused connection,
				// timeout — the instance never answered.
				return { instance, data: null, kind: 'network' };
			}
		})
	);

	const upcomingEvents: MergedEvent[] = [];
	const recentActivity: MergedPost[] = [];
	const failedInstances: FailedInstance[] = [];

	for (const result of results) {
		if (!result.data) {
			failedInstances.push({ instance: result.instance, kind: result.kind });
			continue;
		}
		for (const event of result.data.upcoming_events) {
			upcomingEvents.push({ ...event, instance: result.instance });
		}
		for (const post of result.data.recent_activity) {
			recentActivity.push({ ...post, instance: result.instance });
		}
	}

	upcomingEvents.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
	recentActivity.sort((a, b) => b.published_at.localeCompare(a.published_at));

	return { upcomingEvents, recentActivity, failedInstances };
}
