<script lang="ts">
	import type { Snippet } from 'svelte';
	import { ApiError } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { GuestIdentity } from '$lib/public/api.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';

	/**
	 * The shared shape of the RSVP/signup-claim/comment guest request forms
	 * (issue #185 slice B): every one collects an email + display name, POSTs
	 * to a `request_guest_*` endpoint that always answers a neutral 202 (rate
	 * -limited, no oracle on whether the email is already known — see
	 * `KammerWeb.Api.GuestController`), then shows a "check your email"
	 * terminal state. `extra` renders whatever the specific request needs
	 * beyond identity (an RSVP status picker, a comment body) — the parent
	 * owns that field's state and reads it inside its `onSubmit` closure, so
	 * this component only needs to know when that extra input is valid via
	 * `disabled`.
	 */
	interface Props {
		idPrefix: string;
		onSubmit: (identity: GuestIdentity) => Promise<void>;
		submitLabel: string;
		successTitle: string;
		successBody: string;
		disabled?: boolean;
		extra?: Snippet;
	}

	let {
		idPrefix,
		onSubmit,
		submitLabel,
		successTitle,
		successBody,
		disabled = false,
		extra
	}: Props = $props();

	let email = $state('');
	let displayName = $state('');
	let phase = $state<'idle' | 'submitting' | 'success' | 'error'>('idle');
	let errorMessage = $state('');

	const canSubmit = $derived(
		email.trim().length > 0 && displayName.trim().length > 0 && !disabled && phase !== 'submitting'
	);

	async function submit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (!canSubmit) return;
		phase = 'submitting';
		try {
			await onSubmit({ email: email.trim(), displayName: displayName.trim() });
			phase = 'success';
		} catch (cause) {
			errorMessage =
				cause instanceof ApiError && cause.kind === 'rate_limited'
					? t('public.guestForm.error.rateLimited')
					: t('public.guestForm.error.generic');
			phase = 'error';
		}
	}
</script>

{#if phase === 'success'}
	<EmptyState title={successTitle} body={successBody} />
{:else}
	<form id="{idPrefix}-form" onsubmit={submit} class="flex flex-col gap-3">
		{#if extra}{@render extra()}{/if}
		<Input
			id="{idPrefix}-name"
			label={t('public.guestForm.name')}
			bind:value={displayName}
			autocomplete="name"
			required
		/>
		<Input
			id="{idPrefix}-email"
			label={t('public.guestForm.email')}
			bind:value={email}
			type="email"
			autocomplete="email"
			required
		/>
		{#if phase === 'error'}
			<p class="text-sm text-danger" role="alert">{errorMessage}</p>
		{/if}
		<Button id="{idPrefix}-submit" type="submit" variant="primary" disabled={!canSubmit}>
			{phase === 'submitting' ? t('common.sending') : submitLabel}
		</Button>
	</form>
{/if}
