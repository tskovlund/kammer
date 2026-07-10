<script lang="ts">
	import { onMount } from 'svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	/**
	 * Shared shape of `GuestConfirmation` and `NewsletterConfirmation` — both
	 * are the same API schema (issue #185), so one landing screen covers
	 * RSVP/claim/comment/newsletter confirm: read `token` from the route,
	 * POST it once on mount, then show a neutral success or error state.
	 * Mirrors `/sign-in/[token]`'s loading/error shape.
	 */
	interface Confirmation {
		guest_name: string | null;
		redirect_path: string;
	}

	interface Props {
		token: string | undefined;
		confirm: (baseUrl: string, token: string) => Promise<Confirmation>;
		loadingLabel: string;
		errorTitle: string;
		errorBody: string;
		success: import('svelte').Snippet<[Confirmation]>;
		/**
		 * Overrides the default neutral error state with the caught error —
		 * only the claim confirm page uses this today, to say "this slot
		 * filled up" instead of the generic "link invalid" (a legitimate,
		 * non-oracle-leaking distinction the API already makes via 422
		 * `slot_full`, see `KammerWeb.Api.GuestController.confirm_claim/2`).
		 */
		error?: import('svelte').Snippet<[unknown]>;
	}

	let { token, confirm, loadingLabel, errorTitle, errorBody, success, error }: Props = $props();

	let phase = $state<'loading' | 'success' | 'error'>('loading');
	let result = $state<Confirmation | null>(null);
	let caughtError = $state<unknown>(null);

	onMount(async () => {
		if (!token) {
			phase = 'error';
			return;
		}
		try {
			result = await confirm(window.location.origin, token);
			phase = 'success';
		} catch (cause) {
			caughtError = cause;
			phase = 'error';
		}
	});
</script>

{#if phase === 'loading'}
	<div aria-busy="true" aria-live="polite">
		<p class="text-center text-sm text-ink-muted">{loadingLabel}</p>
		<div class="mt-6 flex flex-col gap-3">
			<Skeleton class="h-11 w-full" />
			<Skeleton class="h-11 w-2/3" />
		</div>
	</div>
{:else if phase === 'error'}
	{#if error}
		{@render error(caughtError)}
	{:else}
		<EmptyState title={errorTitle} body={errorBody} />
	{/if}
{:else if result}
	{@render success(result)}
{/if}
