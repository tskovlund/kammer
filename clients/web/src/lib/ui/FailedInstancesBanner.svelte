<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { FailedInstance } from '$lib/instances/home.js';

	/**
	 * The per-instance failure banners every multi-instance page shows
	 * (#159 failure kinds) — extracted once three pages had drifted copies.
	 * `onRetry` is optional (the events page has nothing live to rewire);
	 * an `auth` failure never offers retry — retrying can't fix a revoked
	 * token, signing in again can.
	 */
	interface Props {
		failures: FailedInstance[];
		onRetry?: (failure: FailedInstance) => void;
	}

	let { failures, onRetry }: Props = $props();
</script>

{#if failures.length > 0}
	<div class="mb-5 flex flex-col gap-2">
		{#each failures as failure (failure.instance.id)}
			<div
				class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm"
				role="status"
			>
				<span class="text-ink-muted">
					{#if failure.kind === 'auth'}
						{t('home.failed.auth', { name: failure.instance.instanceName })}
					{:else if failure.kind === 'network'}
						{t('home.failed.network', { name: failure.instance.instanceName })}
					{:else}
						{t('home.failed.server', { name: failure.instance.instanceName })}
					{/if}
				</span>
				{#if onRetry && failure.kind !== 'auth'}
					<button
						type="button"
						class="shrink-0 text-accent hover:underline"
						onclick={() => onRetry(failure)}
					>
						{t('common.retry')}
					</button>
				{/if}
			</div>
		{/each}
	</div>
{/if}
