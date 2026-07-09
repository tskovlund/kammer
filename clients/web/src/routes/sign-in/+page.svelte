<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { exchangeAndAddInstance, probeInstance, requestLink } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { extractMagicToken, normalizeInstanceUrl } from '$lib/instances/signin.js';
	import Button from '$lib/ui/Button.svelte';
	import Input from '$lib/ui/Input.svelte';

	// Three steps, one screen: address → email → check-your-email. The
	// paste field on the last step covers emails opened on another device
	// or in a mail client that strips deep links; the /sign-in/[token]
	// route covers links opened directly in this PWA.
	let step = $state<'instance' | 'email' | 'confirm'>('instance');
	let address = $state('');
	let email = $state('');
	let paste = $state('');
	let baseUrl = $state('');
	let instanceName = $state('');
	let busy = $state(false);
	let error = $state<string | null>(null);
	let resent = $state(false);

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
			step = 'email';
		} catch {
			error = t('signin.instance.error.unreachable');
		} finally {
			busy = false;
		}
	}

	async function submitEmail(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		busy = true;
		error = null;
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

	function backTo(target: 'instance' | 'email'): void {
		step = target;
		error = null;
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
		<Button id="signin-email-back" variant="ghost" onclick={() => backTo('instance')}>
			{t('common.back')}
		</Button>
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
