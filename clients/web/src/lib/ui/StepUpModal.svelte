<script lang="ts">
	import { ApiError, errorKind } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import {
		canStepUpWithPasskey,
		isStepUpRequired,
		performPasskeyStepUp,
		requestStepUpLink
	} from '$lib/instances/stepup.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import { dismissable } from '$lib/ui/dismissable.js';

	/**
	 * The step-up confirmation dialog (issue #294, ADR 0029): opened when
	 * a credential-changing call answers 401 `step_up_required`. Offers a
	 * passkey confirmation (when the browser and origin allow one) and
	 * the emailed-link fallback with the sign-in flow's check-your-email
	 * step, then retries the caller's original action — the elevation is
	 * server-side, on the device token, so the retry simply succeeds.
	 *
	 * Render it conditionally (`{#if ...}`): mount is open, like
	 * VersionSheet. Escape, backdrop, and the cancel affordance all call
	 * `oncancel`; a successful retry calls `onsuccess` — the parent
	 * unmounts it in both cases.
	 */
	interface Props {
		instance: Instance;
		/** Re-runs the original, gated action. Resolves = it went through. */
		retry: () => Promise<void>;
		onsuccess: () => void;
		oncancel: () => void;
	}

	let { instance, retry, onsuccess, oncancel }: Props = $props();

	let phase = $state<'choose' | 'email-sent'>('choose');
	let busy = $state(false);
	let resent = $state(false);
	let error = $state<string | null>(null);

	const passkeyAvailable = $derived(canStepUpWithPasskey(instance));

	// Tab-trap: `dismissable` handles Escape/outside-click/focus-restore,
	// but a modal must also keep Tab cycling inside (aria-modal promises
	// it). Scoped to the dialog node, capture phase, wrap at the edges.
	function trapTab(node: HTMLElement) {
		function onKeydown(event: KeyboardEvent) {
			if (event.key !== 'Tab') return;
			const focusable = Array.from(
				node.querySelectorAll<HTMLElement>('button:not([disabled]), [href], [tabindex="0"]')
			);
			if (focusable.length === 0) return;
			const first = focusable[0];
			const last = focusable[focusable.length - 1];
			const active = document.activeElement;
			if (event.shiftKey && (active === first || !node.contains(active))) {
				event.preventDefault();
				last.focus();
			} else if (!event.shiftKey && (active === last || !node.contains(active))) {
				event.preventDefault();
				first.focus();
			}
		}
		document.addEventListener('keydown', onKeydown, true);
		return {
			destroy() {
				document.removeEventListener('keydown', onKeydown, true);
			}
		};
	}

	async function withPasskey(): Promise<void> {
		busy = true;
		error = null;
		let outcome: 'stepped_up' | 'cancelled';
		try {
			outcome = await performPasskeyStepUp(instance);
		} catch {
			// The server's one neutral answer for a failed ceremony — no
			// oracle for which step went wrong, so one message here too.
			error = t('stepUp.passkey.error');
			busy = false;
			return;
		}
		// A dismissed OS prompt is a deliberate cancel, not a failure —
		// stay on the chooser, silently (the enrollment flow's stance).
		if (outcome === 'cancelled') {
			busy = false;
			return;
		}
		try {
			await retryOriginal();
		} catch {
			/* retryOriginal set the message */
		} finally {
			busy = false;
		}
	}

	async function sendLink(): Promise<void> {
		busy = true;
		error = null;
		try {
			await requestStepUpLink(instance);
			resent = phase === 'email-sent';
			phase = 'email-sent';
		} catch (cause) {
			error =
				cause instanceof ApiError && cause.kind === 'rate_limited'
					? t('stepUp.email.rateLimited')
					: t('stepUp.email.error');
		} finally {
			busy = false;
		}
	}

	async function continueAfterEmail(): Promise<void> {
		busy = true;
		error = null;
		try {
			await retryOriginal();
		} catch {
			/* retryOriginal set the message */
		} finally {
			busy = false;
		}
	}

	// The retry's own failure vocabulary: still gated means the link
	// wasn't opened yet; anything else is the action's own problem and
	// reads by kind.
	async function retryOriginal(): Promise<void> {
		try {
			await retry();
			onsuccess();
		} catch (cause) {
			error = isStepUpRequired(cause) ? t('stepUp.email.notYet') : t(`errors.${errorKind(cause)}`);
			throw cause;
		}
	}
</script>

<div
	class="fixed inset-0 z-40 flex items-end justify-center bg-ink/40 p-0 sm:items-center sm:p-4"
	role="presentation"
	onclick={(event) => {
		if (event.target === event.currentTarget) oncancel();
	}}
>
	<div
		id="step-up-dialog"
		class="flex w-full max-w-md flex-col rounded-t-2xl border border-line bg-surface sm:rounded-2xl"
		role="dialog"
		aria-modal="true"
		aria-labelledby="step-up-title"
		use:dismissable={{ onDismiss: oncancel }}
		use:trapTab
	>
		<header class="flex items-start justify-between gap-3 border-b border-line px-5 py-4">
			<div>
				<h2 id="step-up-title" class="text-base font-semibold text-ink">
					{t('stepUp.title')}
				</h2>
				<p class="mt-0.5 text-sm text-ink-muted">
					{phase === 'choose'
						? t('stepUp.description')
						: t('stepUp.email.sentDescription', { email: instance.user.email })}
				</p>
			</div>
			<button
				type="button"
				class="shrink-0 rounded-lg p-1.5 text-ink-muted transition-colors duration-150 hover:bg-ink/5 hover:text-ink"
				aria-label={t('common.close')}
				onclick={oncancel}
			>
				<svg
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="1.5"
					class="size-5"
				>
					<path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
				</svg>
			</button>
		</header>

		<div class="flex flex-col gap-3 px-5 py-4">
			{#if error}
				<div
					class="rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
					role="alert"
				>
					{error}
				</div>
			{/if}

			{#if phase === 'choose'}
				{#if passkeyAvailable}
					<Button
						id="step-up-passkey"
						variant="primary"
						disabled={busy}
						onclick={() => void withPasskey()}
					>
						{t('stepUp.passkey')}
					</Button>
				{/if}
				<Button
					id="step-up-email"
					variant={passkeyAvailable ? 'secondary' : 'primary'}
					disabled={busy}
					onclick={() => void sendLink()}
				>
					{busy ? t('common.sending') : t('stepUp.email')}
				</Button>
			{:else}
				<Button
					id="step-up-continue"
					variant="primary"
					disabled={busy}
					onclick={() => void continueAfterEmail()}
				>
					{busy ? t('common.loading') : t('stepUp.email.continue')}
				</Button>
				<div class="flex items-center justify-between gap-2 text-sm text-ink-muted">
					<Button
						id="step-up-resend"
						variant="ghost"
						size="sm"
						disabled={busy}
						onclick={() => void sendLink()}
					>
						{t('stepUp.email.resend')}
					</Button>
					{#if resent}
						<span role="status">{t('stepUp.email.resent')}</span>
					{/if}
				</div>
			{/if}
		</div>
	</div>
</div>
