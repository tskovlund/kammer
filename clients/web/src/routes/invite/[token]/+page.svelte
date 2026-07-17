<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { ApiError } from '$lib/api/errors.js';
	import {
		acceptInvite,
		fetchInvitePreview,
		joinedHref,
		type InvitePreview
	} from '$lib/invites/api.js';
	import { rememberPendingInvite, takePendingInvite } from '$lib/invites/pending.js';
	import {
		exchangeAndAddInstance,
		probeInstance,
		registerAccount,
		registerErrorKeys,
		requestLink
	} from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { extractMagicToken } from '$lib/instances/signin.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import CommunityAccent from '$lib/ui/CommunityAccent.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The invite landing (issue #255): instance-served like the deep-link
	// sign-in route, so `window.location.origin` *is* the instance the
	// token belongs to. A visitor already signed in to this instance gets
	// a one-tap accept; anyone else registers or signs in first — with the
	// token remembered across the email round-trip (see $lib/invites/
	// pending.ts) so arriving back via the magic link still joins.
	const inviteToken = page.params.token ?? '';

	let loadState = $state<'loading' | 'invalid' | 'error' | 'ready'>('loading');
	let preview = $state<InvitePreview | null>(null);
	let signedIn = $state<Instance | null>(null);
	let baseUrl = $state('');
	let instanceName = $state('');
	let registrationOpen = $state(true);
	// A signed-in accept refused for the RIGHT reasons (wrong account) must
	// not dead-end — reveal the register/sign-in branches as the way out.
	let showAlternatives = $state(false);

	// The anonymous path mirrors /sign-in's email → check-your-email dance,
	// with a registration form (the LiveView UserLive.Registration's twin)
	// as the primary branch — invites mostly reach people without accounts.
	let step = $state<'landing' | 'register' | 'signin' | 'confirm'>('landing');
	let displayName = $state('');
	let email = $state('');
	let paste = $state('');
	let busy = $state(false);
	let error = $state<string | null>(null);
	let nameError = $state<string | null>(null);
	let emailError = $state<string | null>(null);
	let resent = $state(false);

	onMount(load);

	// Invite tokens are URL-safe base64 (same shape pending.ts enforces);
	// anything else short-circuits to the invalid state rather than
	// reaching API path-building.
	const TOKEN_SHAPE = /^[A-Za-z0-9_-]+$/;

	async function load(): Promise<void> {
		loadState = 'loading';
		baseUrl = window.location.origin;
		signedIn = instances.list.find(matchesOrigin) ?? null;
		if (!TOKEN_SHAPE.test(inviteToken)) {
			loadState = 'invalid';
			return;
		}
		try {
			preview = await fetchInvitePreview(baseUrl, inviteToken);
			// Best-effort: the exchange step needs a display name for the
			// stored instance; a failed probe must not hide a valid invite
			// (registration stays offered — the server is the enforcer).
			const probe = await probeInstance(baseUrl).catch(() => null);
			instanceName = probe?.instanceName ?? t('app.name');
			registrationOpen = probe?.registrationOpen ?? true;
			loadState = 'ready';
			// The deep-link route lands here when a pending accept was
			// refused — say so up front instead of a bare one-tap button.
			const refused = page.url.searchParams.get('refused');
			if (refused === 'email') {
				error = t('invite.accept.error.emailMismatch');
				showAlternatives = true;
			} else if (refused === 'other') {
				error = t('invite.accept.error.generic');
			}
		} catch (cause) {
			loadState = cause instanceof ApiError && cause.kind === 'not_found' ? 'invalid' : 'error';
		}
	}

	function matchesOrigin(instance: Instance): boolean {
		try {
			return new URL(instance.baseUrl).origin === window.location.origin;
		} catch {
			return false;
		}
	}

	const targetName = $derived(preview ? (preview.group?.name ?? preview.community.name) : '');

	async function enter(instance: Instance): Promise<void> {
		// One join attempt per remembered token, success or not (the
		// pending.ts contract) — a dead invite must not re-fire on a later
		// sign-in; this page still has `inviteToken` for explicit retries.
		// Matching: another invite's pending entry stays untouched.
		takePendingInvite(inviteToken);
		const accepted = await acceptInvite(instance, inviteToken);
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- joinedHref resolves internally
		await goto(joinedHref(instance.id, accepted), { replaceState: true });
	}

	async function acceptSignedIn(): Promise<void> {
		if (!signedIn) return;
		busy = true;
		error = null;
		try {
			await enter(signedIn);
		} catch (cause) {
			error = acceptErrorMessage(cause);
			// Retrying can never fix a wrong-account refusal — offer the
			// register/sign-in branches instead of a dead end.
			if (cause instanceof ApiError && cause.kind === 'forbidden') {
				showAlternatives = true;
			}
		} finally {
			busy = false;
		}
	}

	function acceptErrorMessage(cause: unknown): string {
		// `forbidden` is the accept endpoint's email-mismatch refusal;
		// `not_found` its neutral no-longer-valid collapse (see invites/api).
		if (cause instanceof ApiError && cause.kind === 'forbidden') {
			return t('invite.accept.error.emailMismatch');
		}
		if (cause instanceof ApiError && cause.kind === 'not_found') {
			return t('invite.accept.error.invalid');
		}
		return t('invite.accept.error.generic');
	}

	async function submitRegister(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		busy = true;
		error = null;
		nameError = null;
		emailError = null;
		try {
			rememberPendingInvite(inviteToken);
			await registerAccount(baseUrl, { email, displayName });
			step = 'confirm';
			resent = false;
		} catch (cause) {
			applyRegisterError(cause);
		} finally {
			busy = false;
		}
	}

	function applyRegisterError(cause: unknown): void {
		const keys = registerErrorKeys(cause);
		nameError = keys.nameKey ? t(keys.nameKey) : null;
		emailError = keys.emailKey ? t(keys.emailKey) : null;
		error = keys.formKey ? t(keys.formKey) : null;
	}

	async function submitEmail(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		busy = true;
		error = null;
		try {
			rememberPendingInvite(inviteToken);
			await requestLink(baseUrl, email);
			step = 'confirm';
			resent = false;
		} catch {
			error = t('signin.email.error');
		} finally {
			busy = false;
		}
	}

	async function submitPaste(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		const magicToken = extractMagicToken(paste);
		if (!magicToken) {
			error = t('signin.confirm.error.invalidPaste');
			return;
		}
		busy = true;
		error = null;
		let instance: Instance;
		try {
			instance = await exchangeAndAddInstance(baseUrl, magicToken, instanceName);
			instances.refresh();
		} catch {
			error = t('signin.confirm.error.exchange');
			busy = false;
			return;
		}
		// Signed in — from here a failed accept lands back on the landing
		// step's one-tap button (with the reason), never back at sign-in.
		try {
			await enter(instance);
		} catch (cause) {
			signedIn = instance;
			step = 'landing';
			error = acceptErrorMessage(cause);
			// A fresh signed-in identity resets the dead-end escape hatch:
			// only a wrong-account refusal warrants re-showing the branches —
			// a transient failure must keep the one-tap retry reachable.
			showAlternatives = cause instanceof ApiError && cause.kind === 'forbidden';
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

	// Any step switch drops stale error/confirmation state — an accept
	// failure must not follow the visitor into the registration form.
	function goTo(target: 'landing' | 'register' | 'signin'): void {
		step = target;
		error = null;
		nameError = null;
		emailError = null;
		resent = false;
	}
</script>

<svelte:head>
	<title>{preview ? `${t('invite.title', { name: targetName })} · ` : ''}{t('app.name')}</title>
</svelte:head>

<!-- Once the token resolves, the community IS known — so the landing
     carries its branding (SPEC §21), same best-effort re-tint as the
     public community tree: null until then keeps the default accent,
     no extra fetch — the preview this page already loads carries the
     `accent_color`. -->
<CommunityAccent accentColor={preview?.community.accent_color ?? null}>
	<PublicShell>
		{#if loadState === 'loading'}
			<div aria-busy="true" aria-live="polite" class="flex flex-col gap-3">
				<Skeleton class="h-11 w-full" />
				<Skeleton class="h-11 w-2/3" />
			</div>
		{:else if loadState === 'invalid'}
			<EmptyState title={t('invite.invalid.title')} body={t('invite.invalid.body')} />
		{:else if loadState === 'error'}
			<EmptyState title={t('invite.error.title')} body={t('invite.error.body')}>
				<Button id="invite-retry" variant="primary" onclick={load}>{t('common.retry')}</Button>
			</EmptyState>
		{:else if preview}
			{#if step === 'landing'}
				<div class="text-center">
					<h1 class="text-lg font-semibold text-ink">{t('invite.title', { name: targetName })}</h1>
					{#if preview.group}
						<p class="mt-1 text-sm text-ink-muted">
							{t('invite.groupContext', { name: preview.community.name })}
						</p>
					{:else if preview.community.description}
						<p class="mt-1 text-sm leading-relaxed text-ink-muted">
							{preview.community.description}
						</p>
					{/if}
					{#if preview.community.require_real_names}
						<p class="mt-4 rounded-lg border border-line p-3 text-sm text-ink-muted">
							{t('invite.realNames')}
						</p>
					{/if}

					{#if signedIn && !showAlternatives}
						<div class="mt-6 flex flex-col gap-3">
							<p class="text-sm text-ink-muted">
								{t('invite.signedInAs', { email: signedIn.user.email })}
							</p>
							<Button id="invite-accept" variant="primary" disabled={busy} onclick={acceptSignedIn}>
								{t('invite.accept')}
							</Button>
						</div>
					{:else}
						<div class="mt-6 flex flex-col gap-3">
							{#if registrationOpen}
								<Button id="invite-register" variant="primary" onclick={() => goTo('register')}>
									{t('invite.register')}
								</Button>
							{/if}
							<Button
								id="invite-signin"
								variant={registrationOpen ? 'ghost' : 'primary'}
								onclick={() => goTo('signin')}
							>
								{t('invite.signIn')}
							</Button>
							{#if registrationOpen}
								<p class="text-sm text-ink-faint">{t('invite.newHere')}</p>
							{/if}
						</div>
					{/if}
					<p class="mt-3 text-sm text-danger" role="alert" aria-live="polite">
						{#if error}{error}{/if}
					</p>
				</div>
			{:else if step === 'register'}
				<h1 class="text-lg font-semibold text-ink">{t('register.title')}</h1>
				<p class="mt-1 text-sm leading-relaxed text-ink-muted">{t('register.description')}</p>
				<form id="invite-register-form" class="mt-6 flex flex-col gap-4" onsubmit={submitRegister}>
					<Input
						id="register-display-name"
						label={t('register.displayName')}
						bind:value={displayName}
						error={nameError}
						type="text"
						autocomplete="name"
						required
					/>
					<Input
						id="register-email"
						label={t('register.email')}
						bind:value={email}
						error={emailError}
						type="email"
						autocomplete="email"
						required
					/>
					<Button id="register-submit" variant="primary" type="submit" disabled={busy}>
						{t('register.submit')}
					</Button>
					<Button id="register-back" variant="ghost" onclick={() => goTo('landing')}>
						{t('common.back')}
					</Button>
					<p class="text-sm text-danger" role="alert" aria-live="polite">
						{#if error}{error}{/if}
					</p>
				</form>
			{:else if step === 'signin'}
				<h1 class="text-lg font-semibold text-ink">
					{t('signin.email.title', { name: instanceName })}
				</h1>
				<p class="mt-1 text-sm leading-relaxed text-ink-muted">{t('signin.email.description')}</p>
				<form id="invite-signin-form" class="mt-6 flex flex-col gap-4" onsubmit={submitEmail}>
					<Input
						id="invite-signin-email"
						label={t('signin.email.label')}
						bind:value={email}
						{error}
						type="email"
						autocomplete="email"
						required
					/>
					<Button id="invite-signin-submit" variant="primary" type="submit" disabled={busy}>
						{t('signin.email.submit')}
					</Button>
					<Button id="invite-signin-back" variant="ghost" onclick={() => goTo('landing')}>
						{t('common.back')}
					</Button>
				</form>
			{:else}
				<h1 class="text-lg font-semibold text-ink">{t('signin.confirm.title')}</h1>
				<p class="mt-1 text-sm leading-relaxed text-ink-muted">
					{t('signin.confirm.description', { email })}
				</p>
				<form id="invite-confirm-form" class="mt-6 flex flex-col gap-4" onsubmit={submitPaste}>
					<Input
						id="invite-paste"
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
					<Button id="invite-confirm-submit" variant="primary" type="submit" disabled={busy}>
						{t('signin.confirm.submit')}
					</Button>
					<div class="flex items-center justify-between">
						<Button
							id="invite-confirm-back"
							variant="ghost"
							size="sm"
							onclick={() => goTo('landing')}
						>
							{t('common.back')}
						</Button>
						<Button
							id="invite-confirm-resend"
							variant="ghost"
							size="sm"
							disabled={busy}
							onclick={resend}
						>
							{t('signin.confirm.resend')}
						</Button>
					</div>
					<p class="text-sm text-ink-muted" aria-live="polite">
						{#if resent}{t('signin.confirm.resent')}{/if}
					</p>
				</form>
			{/if}
		{/if}
	</PublicShell>
</CommunityAccent>
