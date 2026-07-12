<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { ApiError } from '$lib/api/errors.js';
	import { completeSetup, fetchSetupStatus, type SetupResult } from '$lib/setup/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// First-run setup wizard (SPEC §13, ADR 0010) — the PWA twin of
	// `KammerWeb.SetupLive.Wizard`, over the API instead of LiveView
	// (ADR 0024: new user-facing surfaces land in the API/PWA, not
	// LiveView). There is deliberately no separate token-verification step
	// (issue #230): a pre-flight check would be a boolean oracle over the
	// setup credential, and `POST /setup` already validates the token
	// server-side on every submission. So the setup token rides the
	// operator step's form alongside the rest of the operator fields, and
	// only the final `community` step's submit (which is the one that
	// calls `completeSetup`) can discover it was wrong — via a neutral
	// 403 `forbidden`, surfaced at that form's error slot.
	type Step = 'operator' | 'community' | 'done';
	const steps: Step[] = ['operator', 'community', 'done'];
	const stepLabel: Record<Step, () => string> = {
		operator: () => t('setup.steps.operator'),
		community: () => t('setup.steps.community'),
		done: () => t('setup.steps.done')
	};

	let checkState = $state<'checking' | 'already-done' | 'wizard' | 'error'>('checking');
	let step = $state<Step>('operator');

	let setupToken = $state('');

	let operatorEmail = $state('');
	let operatorDisplayName = $state('');
	let instanceName = $state('');
	let defaultLocale = $state<'en' | 'da'>('en');
	let communityCreationPolicy = $state<'operators_only' | 'any_user'>('operators_only');
	let operatorError = $state<string | null>(null);

	let communityName = $state('');
	let communitySlug = $state('');
	let accentColor = $state('#3E6B48');
	let groupName = $state(t('setup.community.groupNameDefault'));
	let groupSlug = $state('general');
	let demoData = $state(false);
	let communityBusy = $state(false);
	let communityError = $state<string | null>(null);

	let result = $state<SetupResult | null>(null);

	onMount(async () => {
		try {
			const completed = await fetchSetupStatus(window.location.origin);
			checkState = completed ? 'already-done' : 'wizard';
		} catch {
			checkState = 'error';
		}
	});

	function stepReached(target: Step): boolean {
		return steps.indexOf(step) >= steps.indexOf(target);
	}

	function submitOperator(event: SubmitEvent): void {
		event.preventDefault();
		if (operatorEmail.trim() === '') {
			operatorError = t('setup.operator.error.emailRequired');
			return;
		}
		operatorError = null;
		step = 'community';
	}

	async function submitCommunity(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		communityBusy = true;
		communityError = null;
		try {
			result = await completeSetup(window.location.origin, {
				token: setupToken.trim(),
				operator: {
					email: operatorEmail.trim(),
					display_name: operatorDisplayName.trim() || null
				},
				instance: {
					instance_name: instanceName.trim() || null,
					default_locale: defaultLocale,
					community_creation_policy: communityCreationPolicy
				},
				community: {
					name: communityName.trim(),
					slug: communitySlug.trim(),
					accent_color: accentColor
				},
				group: { name: groupName.trim(), slug: groupSlug.trim() },
				demo_data: demoData
			});
			step = 'done';
		} catch (cause) {
			// A bad or already-consumed setup token surfaces here as a
			// neutral 403 `forbidden` — there is no earlier token-check step
			// to catch it at (see the module doc comment above).
			if (cause instanceof ApiError && cause.kind === 'forbidden') {
				communityError = t('setup.token.error');
			} else {
				communityError = cause instanceof ApiError ? cause.message : t('setup.error.body');
			}
		} finally {
			communityBusy = false;
		}
	}
</script>

<svelte:head><title>{t('setup.token.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	{#if checkState === 'checking'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('setup.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-11 w-full" />
				<Skeleton class="h-11 w-2/3" />
			</div>
		</div>
	{:else if checkState === 'error'}
		<EmptyState title={t('setup.error.title')} body={t('setup.error.body')} />
	{:else if checkState === 'already-done'}
		<EmptyState title={t('setup.alreadyDone.title')} body={t('setup.alreadyDone.body')}>
			<Button
				id="setup-already-done-signin"
				variant="primary"
				onclick={() => goto(resolve('/sign-in'))}
			>
				{t('setup.alreadyDone.signIn')}
			</Button>
		</EmptyState>
	{:else}
		<h1 class="text-lg font-semibold text-ink">{t('setup.token.title')}</h1>

		<ol class="mt-4 flex gap-2 text-xs text-ink-faint" aria-label={t('setup.token.title')}>
			{#each steps as candidate (candidate)}
				<li
					class="flex-1 border-t-2 pt-1.5 {stepReached(candidate)
						? 'border-accent text-ink'
						: 'border-line'}"
				>
					{stepLabel[candidate]()}
				</li>
			{/each}
		</ol>

		{#if step === 'operator'}
			<p class="mt-6 text-sm text-ink-muted">{t('setup.token.description')}</p>
			<form id="setup-operator-form" class="mt-4 flex flex-col gap-4" onsubmit={submitOperator}>
				<Input
					id="setup-token-input"
					label={t('setup.token.label')}
					bind:value={setupToken}
					hint={t('setup.token.hint')}
					placeholder={t('setup.token.placeholder')}
					autocomplete="off"
					required
				/>
				<Input
					id="setup-operator-email"
					type="email"
					label={t('setup.operator.email')}
					bind:value={operatorEmail}
					error={operatorError}
					required
				/>
				<Input
					id="setup-operator-display-name"
					label={t('setup.operator.displayName')}
					bind:value={operatorDisplayName}
					required
				/>
				<Input
					id="setup-instance-name"
					label={t('setup.operator.instanceName')}
					bind:value={instanceName}
					placeholder={t('setup.operator.instanceNamePlaceholder')}
				/>
				<label class="flex flex-col gap-1.5">
					<span class="text-sm font-medium text-ink">{t('setup.operator.localeLabel')}</span>
					<select
						id="setup-default-locale"
						bind:value={defaultLocale}
						class="h-11 rounded-lg border border-line bg-surface px-3 text-sm text-ink"
					>
						<option value="en">{t('setup.operator.localeEn')}</option>
						<option value="da">{t('setup.operator.localeDa')}</option>
					</select>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-sm font-medium text-ink">{t('setup.operator.policyLabel')}</span>
					<select
						id="setup-community-creation-policy"
						bind:value={communityCreationPolicy}
						class="h-11 rounded-lg border border-line bg-surface px-3 text-sm text-ink"
					>
						<option value="operators_only">{t('setup.operator.policyOperatorsOnly')}</option>
						<option value="any_user">{t('setup.operator.policyAnyUser')}</option>
					</select>
				</label>
				<Button id="setup-operator-submit" variant="primary" type="submit">
					{t('setup.operator.continue')}
				</Button>
			</form>
		{:else if step === 'community'}
			<p class="mt-6 text-sm text-ink-muted">{t('setup.community.description')}</p>
			<form id="setup-community-form" class="mt-4 flex flex-col gap-4" onsubmit={submitCommunity}>
				{#if communityError}
					<div
						class="rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
						role="alert"
					>
						{communityError}
					</div>
				{/if}
				<Input
					id="setup-community-name"
					label={t('setup.community.name')}
					bind:value={communityName}
					required
				/>
				<Input
					id="setup-community-slug"
					label={t('setup.community.slug')}
					bind:value={communitySlug}
					placeholder={t('setup.community.slugPlaceholder')}
					required
				/>
				<Input
					id="setup-community-accent-color"
					type="color"
					label={t('setup.community.accentColor')}
					bind:value={accentColor}
				/>
				<Input
					id="setup-group-name"
					label={t('setup.community.groupName')}
					bind:value={groupName}
					required
				/>
				<Input
					id="setup-group-slug"
					label={t('setup.community.groupSlug')}
					bind:value={groupSlug}
					required
				/>
				<label class="flex items-start gap-3 rounded-xl border border-line p-4">
					<input
						id="setup-demo-data"
						type="checkbox"
						bind:checked={demoData}
						class="mt-0.5 size-4 rounded border-line text-accent focus:ring-accent"
					/>
					<span class="text-sm">
						<span class="font-medium text-ink">{t('setup.community.demoData.label')}</span>
						<br />
						<span class="text-ink-muted">{t('setup.community.demoData.description')}</span>
					</span>
				</label>
				<Button
					id="setup-community-submit"
					variant="primary"
					type="submit"
					disabled={communityBusy}
				>
					{communityBusy ? t('setup.community.submitting') : t('setup.community.submit')}
				</Button>
			</form>
		{:else if step === 'done' && result}
			<div class="mt-6 rounded-xl border border-line p-6 text-center">
				<h2 class="text-base font-medium text-ink">{t('setup.done.title')}</h2>
				<p class="mt-2 text-sm text-ink-muted">
					{result.magic_link_sent ? t('setup.done.magicLinkSent') : t('setup.done.magicLinkFailed')}
				</p>
			</div>

			<div class="mt-6">
				<h3 class="text-sm font-medium uppercase tracking-wide text-ink-faint">
					{t('setup.done.inviteHeading')}
				</h3>
				<p
					id="setup-invite-url"
					class="mt-2 rounded-lg border border-line bg-paper p-3 font-mono text-sm break-all text-ink"
				>
					{result.invite_url}
				</p>
				<p class="mt-2 text-sm text-ink-muted">
					{t('setup.done.inviteHint', { community: result.community_slug })}
				</p>
			</div>

			<p class="mt-6 rounded-lg border border-line p-4 text-sm text-ink-muted">
				{t('setup.done.legalHint')}
			</p>

			<Button
				id="setup-done-signin"
				variant="primary"
				class="mt-6 w-full"
				onclick={() => goto(resolve('/sign-in'))}
			>
				{t('setup.done.goToSignIn')}
			</Button>
		{/if}
	{/if}
</PublicShell>
