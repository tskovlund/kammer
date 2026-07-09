<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { exchangeAndAddInstance, probeInstance } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// Deep-link sign-in for the instance-served PWA (forward-looking:
	// today the server emails /users/log-in/{token}; #176/#177 flip the
	// emails to this route once the instance serves the client). When
	// that lands, the instance to exchange against is exactly where this
	// page is served from — no address entry needed. On failure the
	// token stays in history, which is acceptable: exchange failure
	// means the single-use token is already dead or was never valid.
	let failed = $state(false);

	onMount(async () => {
		const token = page.params.token;
		if (!token) {
			failed = true;
			return;
		}
		const origin = window.location.origin;
		try {
			const { instanceName } = await probeInstance(origin);
			await exchangeAndAddInstance(origin, token, instanceName);
			instances.refresh();
			await goto(resolve('/'), { replaceState: true });
		} catch {
			failed = true;
		}
	});
</script>

<svelte:head><title>{t('signin.deeplink.title')} · {t('app.name')}</title></svelte:head>

{#if failed}
	<EmptyState title={t('signin.deeplink.error.title')} body={t('signin.deeplink.error.body')}>
		<Button
			id="signin-deeplink-start-over"
			variant="primary"
			onclick={() => goto(resolve('/sign-in'))}
		>
			{t('signin.deeplink.startOver')}
		</Button>
	</EmptyState>
{:else}
	<div aria-busy="true" aria-live="polite">
		<p class="text-center text-sm text-ink-muted">{t('signin.deeplink.title')}</p>
		<div class="mt-6 flex flex-col gap-3">
			<Skeleton class="h-11 w-full" />
			<Skeleton class="h-11 w-2/3" />
		</div>
	</div>
{/if}
