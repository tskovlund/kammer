<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { instancesForOrigin, instanceStore } from '$lib/instances/store.js';
	import { confirmEmailChange } from '$lib/people/api.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';

	// The email-change confirmation landing (issue #258). Unlike the
	// guest confirms, the emailed token isn't a credential on its own —
	// the confirm endpoint requires the account's device token, so the
	// page resolves the instance this origin serves (the emailed link
	// always points at the instance that sent it) and calls it with the
	// token that instance already holds. No signed-in instance for this
	// origin means the visitor must sign in first, then reopen the link.
	//
	// Confirmation is gated behind an explicit button, not fired on
	// mount: an email change is an identity change, and it must not
	// complete silently just because a forwarded link was opened on a
	// device that happens to hold the account (a mail scanner carries no
	// device token, so prefetch is already inert — this covers the human
	// case).
	type Phase = 'ready' | 'not-signed-in' | 'success' | 'invalid' | 'retry';
	let phase = $state<Phase>('ready');
	let candidates = $state<Instance[]>([]);
	let busy = $state(false);
	let newEmail = $state('');

	const linkClass =
		'inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-surface px-4 text-sm font-medium text-ink transition-colors duration-150 hover:border-ink-faint/60';

	onMount(() => {
		if (!page.params.token) {
			phase = 'invalid';
			return;
		}
		candidates = instancesForOrigin(instanceStore.list(), window.location.origin);
		if (candidates.length === 0) phase = 'not-signed-in';
	});

	async function confirm(): Promise<void> {
		const token = page.params.token;
		if (!token) return;
		busy = true;

		// One server can hold several signed-in accounts, and the token is
		// bound to exactly one (the server answers a neutral 404 for the
		// others WITHOUT consuming it) — so try each in turn. Track whether
		// any attempt failed for a transient reason: if every candidate
		// answered 404 the token is genuinely dead (or for an account not
		// added here); a network/server error means the token likely still
		// lives and the visitor should retry rather than be told it's dead.
		let sawTransient = false;
		for (const instance of candidates) {
			try {
				const { profile, deviceToken } = await confirmEmailChange(instance, token);
				// Persist the new address and the rotated credential (the old
				// device token died with the change) — add() replaces the entry
				// for the same (baseUrl, user).
				instanceStore.add({
					...instance,
					deviceToken,
					user: { ...instance.user, email: profile.email }
				});
				instances.refresh();
				newEmail = profile.email;
				phase = 'success';
				busy = false;
				return;
			} catch (cause) {
				if (!(cause instanceof ApiError) || cause.kind !== 'not_found') sawTransient = true;
			}
		}

		phase = sawTransient ? 'retry' : 'invalid';
		busy = false;
	}
</script>

<svelte:head><title>{t('confirmEmail.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	{#if phase === 'ready'}
		<EmptyState title={t('confirmEmail.ready.title')} body={t('confirmEmail.ready.body')}>
			<Button id="confirm-email-confirm" variant="primary" disabled={busy} onclick={confirm}>
				{busy ? t('common.sending') : t('confirmEmail.ready.confirm')}
			</Button>
		</EmptyState>
	{:else if phase === 'success'}
		<EmptyState
			title={t('confirmEmail.success.title')}
			body={t('confirmEmail.success.body', { email: newEmail })}
		>
			<a href={resolve('/you')} class={linkClass} id="confirm-email-open-app">
				{t('confirmEmail.success.open')}
			</a>
		</EmptyState>
	{:else if phase === 'not-signed-in'}
		<EmptyState
			title={t('confirmEmail.notSignedIn.title')}
			body={t('confirmEmail.notSignedIn.body')}
		>
			<a href={resolve('/sign-in')} class={linkClass} id="confirm-email-sign-in">
				{t('confirmEmail.notSignedIn.signIn')}
			</a>
		</EmptyState>
	{:else if phase === 'retry'}
		<EmptyState title={t('confirmEmail.retry.title')} body={t('confirmEmail.retry.body')}>
			<Button id="confirm-email-retry" variant="primary" disabled={busy} onclick={confirm}>
				{busy ? t('common.sending') : t('confirmEmail.retry.tryAgain')}
			</Button>
		</EmptyState>
	{:else}
		<EmptyState title={t('confirmEmail.error.title')} body={t('confirmEmail.error.body')} />
	{/if}
</PublicShell>
