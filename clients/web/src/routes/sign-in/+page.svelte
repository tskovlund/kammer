<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import {
		exchangeAndAddInstance,
		passkeySignInAndAddInstance,
		probeInstance,
		registerAccount,
		registerErrorKeys,
		requestLink
	} from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { extractMagicToken, normalizeInstanceUrl } from '$lib/instances/signin.js';
	import { isPasskeySupported, sameOriginInstance } from '$lib/instances/webauthn.js';
	import Button from '$lib/ui/Button.svelte';
	import Input from '$lib/ui/Input.svelte';

	// Three steps, one screen: address → email → check-your-email. The
	// paste field on the last step covers emails opened on another device
	// or in a mail client that strips deep links; the /sign-in/[token]
	// route covers links opened directly in this PWA. When the probed
	// instance has open registration, the email step also branches into a
	// create-account form (issue #255) that ends on the same confirm step
	// — registering emails the identical magic link.
	let step = $state<'instance' | 'email' | 'register' | 'confirm'>('instance');
	let address = $state('');
	let email = $state('');
	let displayName = $state('');
	let paste = $state('');
	let baseUrl = $state('');
	let instanceName = $state('');
	let registrationOpen = $state(false);
	let busy = $state(false);
	let error = $state<string | null>(null);
	let nameError = $state<string | null>(null);
	let emailError = $state<string | null>(null);
	let passkeyError = $state<string | null>(null);
	let resent = $state(false);

	// CSR-only app (root layout sets ssr = false), so the browser globals
	// isPasskeySupported reads are always present — a plain init call, no
	// onMount dance. Browser capability is fixed for the session.
	const browserSupportsPasskeys = isPasskeySupported();

	// Offer the passkey affordance only when it can actually succeed —
	// never a button that can only fail. Beyond browser capability that
	// means the *same-origin* instance (WebAuthn ties the assertion to the
	// server-minted rp_id): `sameOriginInstance` carries that reasoning.
	const passkeySupported = $derived(browserSupportsPasskeys && sameOriginInstance(baseUrl));

	async function submitInstance(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		const normalized = normalizeInstanceUrl(address);
		if (!normalized) {
			error = t('signin.instance.error.invalid');
			return;
		}
		busy = true;
		error = null;
		try {
			const probe = await probeInstance(normalized);
			baseUrl = normalized;
			instanceName = probe.instanceName;
			registrationOpen = probe.registrationOpen;
			step = 'email';
		} catch {
			error = t('signin.instance.error.unreachable');
		} finally {
			busy = false;
		}
	}

	async function submitRegister(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		busy = true;
		error = null;
		nameError = null;
		emailError = null;
		try {
			await registerAccount(baseUrl, { email, displayName });
			step = 'confirm';
			resent = false;
		} catch (cause) {
			const keys = registerErrorKeys(cause);
			nameError = keys.nameKey ? t(keys.nameKey) : null;
			emailError = keys.emailKey ? t(keys.emailKey) : null;
			error = keys.formKey ? t(keys.formKey) : null;
		} finally {
			busy = false;
		}
	}

	async function submitEmail(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		busy = true;
		error = null;
		passkeyError = null;
		try {
			await requestLink(baseUrl, email);
			step = 'confirm';
			resent = false;
		} catch {
			error = t('signin.email.error');
		} finally {
			busy = false;
		}
	}

	// The credential-based path off the email step: no link, no email —
	// the resident passkey both identifies the account and signs in, then
	// lands on the same added-instance state as the magic-link flow.
	async function submitPasskey(): Promise<void> {
		busy = true;
		error = null;
		passkeyError = null;
		try {
			await passkeySignInAndAddInstance(baseUrl, instanceName);
			instances.refresh();
			await goto(resolve('/'));
		} catch {
			passkeyError = t('signin.passkey.error');
		} finally {
			busy = false;
		}
	}

	async function submitPaste(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		const token = extractMagicToken(paste);
		if (!token) {
			error = t('signin.confirm.error.invalidPaste');
			return;
		}
		busy = true;
		error = null;
		try {
			await exchangeAndAddInstance(baseUrl, token, instanceName);
			instances.refresh();
			await goto(resolve('/'));
		} catch {
			error = t('signin.confirm.error.exchange');
		} finally {
			busy = false;
		}
	}

	async function resend(): Promise<void> {
		busy = true;
		error = null;
		try {
			await requestLink(baseUrl, email);
			resent = true;
		} catch {
			error = t('signin.email.error');
		} finally {
			busy = false;
		}
	}

	// Also the way *into* the register step — the shared point is that
	// switching steps drops any stale error/confirmation state.
	function backTo(target: 'instance' | 'email' | 'register'): void {
		step = target;
		error = null;
		nameError = null;
		emailError = null;
		passkeyError = null;
		resent = false;
	}
</script>

<svelte:head><title>{t('signin.instance.title')} · {t('app.name')}</title></svelte:head>

{#if step === 'instance'}
	<h1 class="text-lg font-semibold text-ink">{t('signin.instance.title')}</h1>
	<p class="mt-1 text-sm leading-relaxed text-ink-muted">{t('signin.instance.description')}</p>
	<form id="signin-instance-form" class="mt-6 flex flex-col gap-4" onsubmit={submitInstance}>
		<Input
			id="signin-instance-url"
			label={t('signin.instance.label')}
			bind:value={address}
			{error}
			placeholder={t('signin.instance.placeholder')}
			type="text"
			inputmode="url"
			autocomplete="url"
			autocapitalize="off"
			spellcheck={false}
			required
		/>
		<Button id="signin-instance-submit" variant="primary" type="submit" disabled={busy}>
			{t('signin.instance.continue')}
		</Button>
	</form>
	{#if instances.list.length > 0}
		<!-- Adding another community from the You tab — offer a way back. -->
		<p class="mt-6 text-center">
			<a
				id="signin-back-to-app"
				href={resolve('/you')}
				class="text-sm text-ink-muted underline decoration-line underline-offset-4 transition-colors duration-150 hover:text-ink"
			>
				{t('signin.backToApp')}
			</a>
		</p>
	{/if}
{:else if step === 'email'}
	<h1 class="text-lg font-semibold text-ink">
		{t('signin.email.title', { name: instanceName })}
	</h1>
	<p class="mt-1 text-sm leading-relaxed text-ink-muted">{t('signin.email.description')}</p>
	<form id="signin-email-form" class="mt-6 flex flex-col gap-4" onsubmit={submitEmail}>
		<Input
			id="signin-email"
			label={t('signin.email.label')}
			bind:value={email}
			{error}
			type="email"
			autocomplete="email"
			required
		/>
		<Button id="signin-email-submit" variant="primary" type="submit" disabled={busy}>
			{t('signin.email.submit')}
		</Button>
		{#if passkeySupported}
			<div class="flex items-center gap-3 text-xs text-ink-muted" aria-hidden="true">
				<span class="h-px flex-1 bg-line"></span>
				{t('signin.passkey.or')}
				<span class="h-px flex-1 bg-line"></span>
			</div>
			<Button id="signin-passkey" variant="secondary" disabled={busy} onclick={submitPasskey}>
				{t('signin.passkey.button')}
			</Button>
			<p class="text-sm text-danger" role="alert" aria-live="polite">
				{#if passkeyError}{passkeyError}{/if}
			</p>
		{/if}
		{#if registrationOpen}
			<Button id="signin-email-register" variant="ghost" onclick={() => backTo('register')}>
				{t('signin.email.register')}
			</Button>
		{/if}
		<Button id="signin-email-back" variant="ghost" onclick={() => backTo('instance')}>
			{t('common.back')}
		</Button>
	</form>
{:else if step === 'register'}
	<h1 class="text-lg font-semibold text-ink">{t('register.title')}</h1>
	<p class="mt-1 text-sm leading-relaxed text-ink-muted">{t('register.description')}</p>
	<form id="signin-register-form" class="mt-6 flex flex-col gap-4" onsubmit={submitRegister}>
		<Input
			id="signin-register-display-name"
			label={t('register.displayName')}
			bind:value={displayName}
			error={nameError}
			type="text"
			autocomplete="name"
			required
		/>
		<Input
			id="signin-register-email"
			label={t('register.email')}
			bind:value={email}
			error={emailError}
			type="email"
			autocomplete="email"
			required
		/>
		<Button id="signin-register-submit" variant="primary" type="submit" disabled={busy}>
			{t('register.submit')}
		</Button>
		<Button id="signin-register-back" variant="ghost" onclick={() => backTo('email')}>
			{t('common.back')}
		</Button>
		<p class="text-sm text-danger" role="alert" aria-live="polite">
			{#if error}{error}{/if}
		</p>
	</form>
{:else}
	<h1 class="text-lg font-semibold text-ink">{t('signin.confirm.title')}</h1>
	<p class="mt-1 text-sm leading-relaxed text-ink-muted">
		{t('signin.confirm.description', { email })}
	</p>
	<form id="signin-confirm-form" class="mt-6 flex flex-col gap-4" onsubmit={submitPaste}>
		<Input
			id="signin-paste"
			label={t('signin.confirm.pasteLabel')}
			bind:value={paste}
			{error}
			hint={t('signin.confirm.pasteHint')}
			type="text"
			autocomplete="off"
			autocapitalize="off"
			spellcheck={false}
			required
		/>
		<Button id="signin-confirm-submit" variant="primary" type="submit" disabled={busy}>
			{t('signin.confirm.submit')}
		</Button>
		<div class="flex items-center justify-between">
			<Button id="signin-confirm-back" variant="ghost" size="sm" onclick={() => backTo('email')}>
				{t('signin.email.back')}
			</Button>
			<Button id="signin-confirm-resend" variant="ghost" size="sm" disabled={busy} onclick={resend}>
				{t('signin.confirm.resend')}
			</Button>
		</div>
		<p class="text-sm text-ink-muted" aria-live="polite">
			{#if resent}{t('signin.confirm.resent')}{/if}
		</p>
	</form>
{/if}
