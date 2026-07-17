import { t } from '$lib/i18n/i18n.svelte.js';
import type { FailedInstance } from './home.js';
import { instances } from './instances.svelte.js';

/**
 * The one source of the per-instance failure line (#159 kinds): with a
 * single account (#322) the copy drops the instance name — there is
 * nothing to disambiguate from. Shared by the failure banner and the
 * search page so the copy can't drift apart again.
 */
export function failureMessage(failure: FailedInstance): string {
	return instances.solo
		? t(`home.failed.${failure.kind}Solo`)
		: t(`home.failed.${failure.kind}`, { name: failure.instance.instanceName });
}
