<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import type { MessageKey } from '$lib/i18n/format.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import {
		fetchInstanceSettings,
		updateInstanceSettings,
		ManageApiError,
		type InstanceSettings,
		type InstanceSettingsParams,
		type ManageErrorKind
	} from '$lib/manage/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const CREATION_POLICY = ['operators_only', 'any_user'] as const;
	const STORAGE_POLICY = ['unmetered', 'quota'] as const;

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let settings = $state<InstanceSettings | null>(null);
	let loading = $state(true);
	// There is no operator capability on the client; the settings read
	// itself is the gate — a non-operator gets a 403, which we surface as
	// the forbidden empty state rather than an editable form.
	let error = $state<ManageErrorKind | null>(null);
	let saving = $state(false);
	let saved = $state(false);

	let instanceName = $state('');
	let locale = $state('en');
	let creationPolicy = $state<string>('operators_only');
	let storagePolicy = $state<string>('unmetered');
	let minimizedEmails = $state(false);

	const backHref = resolve('/you');

	function hydrate(resolved: InstanceSettings): void {
		settings = resolved;
		instanceName = resolved.instance_name ?? '';
		locale = resolved.default_locale;
		creationPolicy = resolved.community_creation_policy;
		storagePolicy = resolved.storage_policy;
		minimizedEmails = resolved.content_minimized_emails;
	}

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolved = await fetchInstanceSettings(inst);
				if (cancelled) return;
				hydrate(resolved);
			} catch (cause) {
				if (!cancelled) error = cause instanceof ManageApiError ? cause.kind : 'server';
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (!instance || !settings || saving) return;
		saving = true;
		saved = false;
		error = null;
		const trimmed = instanceName.trim();
		const params: InstanceSettingsParams = {
			// Blank clears back to the built-in "Kammer" default rather than
			// storing an empty name.
			instance_name: trimmed === '' ? null : trimmed,
			default_locale: locale as InstanceSettingsParams['default_locale'],
			community_creation_policy:
				creationPolicy as InstanceSettingsParams['community_creation_policy'],
			storage_policy: storagePolicy as InstanceSettingsParams['storage_policy'],
			content_minimized_emails: minimizedEmails
		};
		try {
			hydrate(await updateInstanceSettings(instance, params));
			saved = true;
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
		} finally {
			saving = false;
		}
	}

	function policyOptions(
		prefix: 'creationPolicy' | 'storagePolicy',
		values: readonly string[]
	): { value: string; label: string }[] {
		return values.map((value) => ({
			value,
			label: t(`manage.instance.${prefix}Option.${value}` as MessageKey)
		}));
	}
</script>

<svelte:head><title>{t('manage.instance.title')} · {t('app.name')}</title></svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-6 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('nav.you')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('manage.instance.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">{t('manage.instance.subtitle')}</p>
		</div>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
	{:else if error === 'forbidden'}
		<EmptyState
			title={t('manage.error.forbiddenTitle')}
			body={t('manage.instance.forbiddenBody')}
		/>
	{:else if !settings}
		<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
	{:else}
		<form class="flex max-w-lg flex-col gap-4" onsubmit={save}>
			<Input
				id="instance-name"
				label={t('manage.instance.name')}
				placeholder={t('manage.instance.namePlaceholder')}
				bind:value={instanceName}
			/>

			<Select
				id="instance-locale"
				label={t('manage.instance.locale')}
				bind:value={locale}
				options={[
					{ value: 'en', label: t('manage.locale.en') },
					{ value: 'da', label: t('manage.locale.da') }
				]}
			/>

			<Select
				id="instance-creation-policy"
				label={t('manage.instance.creationPolicy')}
				bind:value={creationPolicy}
				options={policyOptions('creationPolicy', CREATION_POLICY)}
			/>

			<Select
				id="instance-storage-policy"
				label={t('manage.instance.storagePolicy')}
				bind:value={storagePolicy}
				options={policyOptions('storagePolicy', STORAGE_POLICY)}
			/>

			<div class="flex flex-col gap-1">
				<label class="flex items-start gap-2 text-sm text-ink">
					<input
						id="instance-minimized-emails"
						type="checkbox"
						bind:checked={minimizedEmails}
						class="mt-0.5 size-4 rounded border-line text-accent focus:ring-accent"
					/>
					{t('manage.instance.minimizedEmails')}
				</label>
				<p class="pl-6 text-sm text-ink-faint">{t('manage.instance.minimizedEmailsHint')}</p>
			</div>

			<div class="flex items-center gap-3">
				<Button type="submit" variant="primary" disabled={saving}>
					{saving ? t('common.sending') : t('manage.instance.save')}
				</Button>
				{#if saved}
					<span class="text-sm text-ink-muted" role="status">{t('manage.instance.saved')}</span>
				{/if}
				{#if error}
					<span class="text-sm text-danger" role="alert">{t('manage.error.body')}</span>
				{/if}
			</div>
		</form>
	{/if}
{/if}
