<script lang="ts">
	import { resolve } from '$app/paths';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { fetchServerVersion, revokeAndRemoveInstance } from '$lib/instances/api.js';
	import { fetchInstanceSettings } from '$lib/manage/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { theme, type ThemePreference } from '$lib/ui/theme.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';

	let signingOutId = $state<string | null>(null);

	// Each account's server version for the about line (#204) — fetched
	// best-effort; a server that doesn't answer simply shows no version.
	// One batch per change to the instance list, written back in a
	// single assignment: the effect must not read serverVersions, or
	// each resolving fetch would rerun it and refire the in-flight ones.
	let serverVersions = $state<Record<string, string>>({});

	$effect(() => {
		const list = instances.list;
		void Promise.all(
			list.map(async (instance) => ({
				id: instance.id,
				version: await fetchServerVersion(instance.baseUrl)
			}))
		).then((results) => {
			const next: Record<string, string> = {};
			for (const { id, version } of results) {
				if (version) next[id] = version;
			}
			serverVersions = next;
		});
	});

	// The instance-operator settings link only shows where this account
	// actually operates the instance. There's no operator capability on
	// the client, so we gate on the settings read itself: a 200 means
	// operator, a 403 means not — best-effort, in one batch (see
	// serverVersions), written back once so a resolving probe never
	// refires the effect.
	let operatorIds = $state<string[]>([]);

	$effect(() => {
		const list = instances.list;
		void Promise.all(
			list.map(async (instance) => {
				try {
					await fetchInstanceSettings(instance);
					return instance.id;
				} catch {
					return null;
				}
			})
		).then((results) => {
			operatorIds = results.filter((id): id is string => id !== null);
		});
	});

	async function signOut(id: string): Promise<void> {
		signingOutId = id;
		try {
			await revokeAndRemoveInstance(id);
			// The (app) layout's guard redirects to /sign-in if this was the
			// last account.
			instances.refresh();
		} finally {
			signingOutId = null;
		}
	}

	function host(baseUrl: string): string {
		try {
			return new URL(baseUrl).host;
		} catch {
			return baseUrl;
		}
	}

	const themeOptions: { value: ThemePreference; label: () => string }[] = [
		{ value: 'system', label: () => t('you.appearance.system') },
		{ value: 'light', label: () => t('you.appearance.light') },
		{ value: 'dark', label: () => t('you.appearance.dark') }
	];

	const localeOptions = [
		{ value: 'en', label: 'English' },
		{ value: 'da', label: 'Dansk' }
	] as const;
</script>

<svelte:head><title>{t('nav.you')} · {t('app.name')}</title></svelte:head>

<h1 class="text-xl font-semibold tracking-tight text-ink">{t('you.title')}</h1>

<section class="mt-8" aria-labelledby="you-accounts-heading">
	<h2 id="you-accounts-heading" class="text-sm font-medium text-ink">
		{t('you.accounts.title')}
	</h2>
	<p class="mt-1 text-sm text-ink-muted">{t('you.accounts.description')}</p>

	<Card class="mt-4 divide-y divide-line">
		{#each instances.list as instance (instance.id)}
			<ListItem>
				<p class="truncate text-sm font-medium text-ink">{instance.instanceName}</p>
				<p class="truncate text-sm text-ink-muted">
					{t('you.accounts.signedInAs', { email: instance.user.email })}
				</p>
				<p class="truncate text-xs text-ink-faint">
					{host(instance.baseUrl)}{serverVersions[instance.id]
						? ` · ${t('you.accounts.serverVersion', { version: serverVersions[instance.id] })}`
						: ''}
				</p>
				<p class="mt-1 flex gap-3 text-sm">
					<!-- eslint-disable svelte/no-navigation-without-resolve -->
					<a href={resolve(`/you/${instance.id}/profile`)} class="text-accent hover:underline">
						{t('you.accounts.profile')}
					</a>
					<a href={resolve(`/you/${instance.id}/devices`)} class="text-accent hover:underline">
						{t('you.accounts.devices')}
					</a>
					<a
						href={resolve(`/you/${instance.id}/notifications`)}
						class="text-accent hover:underline"
					>
						{t('you.accounts.notifications')}
					</a>
					<a href={resolve(`/you/${instance.id}/data`)} class="text-accent hover:underline">
						{t('you.accounts.data')}
					</a>
					{#if operatorIds.includes(instance.id)}
						<a href={resolve(`/you/${instance.id}/settings`)} class="text-accent hover:underline">
							{t('you.accounts.instanceSettings')}
						</a>
					{/if}
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				</p>
				{#snippet trailing()}
					<Button
						variant="danger"
						size="sm"
						id="sign-out-{instance.id}"
						aria-label={t('you.accounts.signOutOf', { name: instance.instanceName })}
						disabled={signingOutId === instance.id}
						onclick={() => signOut(instance.id)}
					>
						{t('you.accounts.signOut')}
					</Button>
				{/snippet}
			</ListItem>
		{/each}
	</Card>

	<div class="mt-4">
		<a
			href={resolve('/sign-in')}
			class="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-surface px-4 text-sm font-medium text-ink transition-colors duration-150 hover:border-ink-faint/60"
		>
			{t('you.accounts.add')}
		</a>
	</div>
</section>

<section class="mt-10" aria-labelledby="you-appearance-heading">
	<h2 id="you-appearance-heading" class="text-sm font-medium text-ink">
		{t('you.appearance.title')}
	</h2>
	<fieldset class="mt-3">
		<legend class="sr-only">{t('you.appearance.title')}</legend>
		<div class="flex max-w-sm gap-1 rounded-lg border border-line bg-paper p-1">
			{#each themeOptions as option (option.value)}
				<label
					class="flex-1 cursor-pointer rounded-md px-3 py-1.5 text-center text-sm transition-colors duration-150 has-checked:bg-surface has-checked:font-medium has-checked:text-ink has-focus-visible:outline-2 has-focus-visible:outline-accent {theme.preference ===
					option.value
						? ''
						: 'text-ink-muted hover:text-ink'}"
				>
					<input
						type="radio"
						name="theme-preference"
						class="sr-only"
						value={option.value}
						checked={theme.preference === option.value}
						onchange={() => theme.setPreference(option.value)}
					/>
					{option.label()}
				</label>
			{/each}
		</div>
	</fieldset>
</section>

<section class="mt-10" aria-labelledby="you-language-heading">
	<h2 id="you-language-heading" class="text-sm font-medium text-ink">
		{t('you.language.title')}
	</h2>
	<fieldset class="mt-3">
		<legend class="sr-only">{t('you.language.title')}</legend>
		<div class="flex max-w-sm gap-1 rounded-lg border border-line bg-paper p-1">
			{#each localeOptions as option (option.value)}
				<label
					class="flex-1 cursor-pointer rounded-md px-3 py-1.5 text-center text-sm transition-colors duration-150 has-checked:bg-surface has-checked:font-medium has-checked:text-ink has-focus-visible:outline-2 has-focus-visible:outline-accent {i18n.locale ===
					option.value
						? ''
						: 'text-ink-muted hover:text-ink'}"
				>
					<input
						type="radio"
						name="locale"
						class="sr-only"
						value={option.value}
						checked={i18n.locale === option.value}
						onchange={() => i18n.setLocale(option.value)}
					/>
					{option.label}
				</label>
			{/each}
		</div>
	</fieldset>
</section>
