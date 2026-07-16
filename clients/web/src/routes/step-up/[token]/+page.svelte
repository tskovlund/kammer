<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { ApiError } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { confirmStepUp } from '$lib/instances/stepup.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';

	// The step-up confirmation landing (issue #294, ADR 0029). The
	// confirm endpoint is public — the emailed link may be opened in a
	// different browser than the app that requested it — so unlike
	// /confirm-email this page needs no signed-in instance: it calls the
	// origin that served it (the emailed link always points at the
	// instance that sent it), token as the whole credential.
	//
	// Confirmation is gated behind an explicit button, not fired on
	// mount, and deliberately so: this link's whole purpose is to prove
	// a human with mailbox access approves a security-sensitive change.
	// If it confirmed on open, a link-following mail scanner — or a
	// reflexively opened forward — would complete a step-up an attacker
	// requested on a stolen device token.
	type Phase = 'ready' | 'success' | 'invalid' | 'retry';
	let phase = $state<Phase>('ready');
	let busy = $state(false);

	onMount(() => {
		if (!page.params.token) phase = 'invalid';
	});

	async function confirm(): Promise<void> {
		const token = page.params.token;
		if (!token) return;
		busy = true;
		try {
			await confirmStepUp(window.location.origin, token);
			phase = 'success';
		} catch (cause) {
			// A neutral 404 means the token is dead (spent, expired,
			// tampered); a network/server hiccup means it likely still
			// lives, so offer a retry instead of declaring it dead.
			phase = cause instanceof ApiError && cause.kind === 'not_found' ? 'invalid' : 'retry';
		} finally {
			busy = false;
		}
	}
</script>

<svelte:head><title>{t('stepUpConfirm.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	{#if phase === 'ready'}
		<EmptyState title={t('stepUpConfirm.ready.title')} body={t('stepUpConfirm.ready.body')}>
			<Button id="step-up-confirm" variant="primary" disabled={busy} onclick={confirm}>
				{busy ? t('common.sending') : t('stepUpConfirm.ready.confirm')}
			</Button>
		</EmptyState>
	{:else if phase === 'success'}
		<EmptyState title={t('stepUpConfirm.success.title')} body={t('stepUpConfirm.success.body')} />
	{:else if phase === 'retry'}
		<EmptyState title={t('stepUpConfirm.retry.title')} body={t('stepUpConfirm.retry.body')}>
			<Button id="step-up-confirm-retry" variant="primary" disabled={busy} onclick={confirm}>
				{busy ? t('common.sending') : t('stepUpConfirm.retry.tryAgain')}
			</Button>
		</EmptyState>
	{:else}
		<EmptyState title={t('stepUpConfirm.error.title')} body={t('stepUpConfirm.error.body')} />
	{/if}
</PublicShell>
