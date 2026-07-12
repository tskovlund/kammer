<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { ApiError } from '$lib/api/errors.js';
	import { exchangeAndAddInstance, probeInstance } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { acceptInvite, joinedHref } from '$lib/invites/api.js';
	import { takePendingInvite } from '$lib/invites/pending.js';
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
			const instance = await exchangeAndAddInstance(origin, token, instanceName);
			instances.refresh();

			// A join attempt in flight (issue #255): the invite landing page
			// remembered its token before sending the visitor through
			// registration/sign-in — accept it now and land in the joined
			// community. The sign-in itself succeeded either way, so a
			// failed accept must not fail the exchange — but it must not be
			// silent either (the newcomer registered specifically to join):
			// land back on the invite page, which renders the signed-in
			// state with the refusal spelled out.
			const pendingInvite = takePendingInvite();
			if (pendingInvite) {
				try {
					const accepted = await acceptInvite(instance, pendingInvite);
					// eslint-disable-next-line svelte/no-navigation-without-resolve -- joinedHref resolves internally
					await goto(joinedHref(instance.id, accepted), { replaceState: true });
				} catch (cause) {
					// Carry the refusal kind so the landing can say what
					// happened instead of showing a bare one-tap button (a
					// dead token 404s at the preview and needs no hint).
					const refused =
						cause instanceof ApiError && cause.kind === 'forbidden'
							? 'email'
							: cause instanceof ApiError && cause.kind === 'not_found'
								? null
								: 'other';
					const suffix = refused ? `?refused=${refused}` : '';
					// eslint-disable-next-line svelte/no-navigation-without-resolve -- resolve() handles the route; the query suffix is a fixed literal
					await goto(resolve(`/invite/${pendingInvite}`) + suffix, { replaceState: true });
				}
				return;
			}
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
