import { readFileSync } from 'node:fs';

/**
 * Pulls the signed-in operator's device token back out of a saved
 * Playwright `storageState` file (01-onboarding.spec.ts writes one after
 * sign-in). The token lives in `localStorage['kammer:instances']`, the
 * same versioned envelope `clients/web/src/lib/instances/store.ts`
 * reads/writes — see that module for the shape.
 */
export function readDeviceToken(storageStatePath: string, origin: string): string {
	const state = JSON.parse(readFileSync(storageStatePath, 'utf8')) as {
		origins: { origin: string; localStorage: { name: string; value: string }[] }[];
	};
	const entry = state.origins.find((candidate) => candidate.origin === origin);
	const raw = entry?.localStorage.find((item) => item.name === 'kammer:instances')?.value;
	if (!raw) throw new Error(`no kammer:instances in storageState for ${origin}`);

	const envelope = JSON.parse(raw) as { instances: { deviceToken: string }[] };
	const [instance] = envelope.instances;
	if (!instance) throw new Error('storageState has no added instances');
	return instance.deviceToken;
}
