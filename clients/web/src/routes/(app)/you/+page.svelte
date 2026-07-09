<script lang="ts">
	import { resolve } from '$app/paths';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { revokeAndRemoveInstance } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { theme, type ThemePreference } from '$lib/ui/theme.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';

	let signingOutId = $state<string | null>(null);

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
				<p class="truncate text-xs text-ink-faint">{host(instance.baseUrl)}</p>
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
