<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { errorKind, type ApiErrorKind } from '$lib/api/errors.js';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import {
		communityParamsErrorKeys,
		updateCommunity,
		type CommunityParams
	} from '$lib/manage/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import CustomFieldsManager from '$lib/manage/CustomFieldsManager.svelte';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ErrorBanner from '$lib/ui/ErrorBanner.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let community = $state<Community | null>(null);
	let loading = $state(true);
	let error = $state<ApiErrorKind | null>(null);
	let saving = $state(false);
	let saved = $state(false);
	// Field-level 422 copy: our own i18n keyed on the changeset field
	// names, never the server's English strings (#253).
	let nameError = $state<string | null>(null);
	let slugError = $state<string | null>(null);

	let name = $state('');
	let slug = $state('');
	let description = $state('');
	let accent = $state('#3E6B48');
	let locale = $state('en');
	let listedOnInstance = $state(false);
	let requireRealNames = $state(false);

	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);
	const moderationHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/moderation`)
	);

	function hydrate(resolved: Community): void {
		community = resolved;
		name = resolved.name;
		slug = resolved.slug;
		description = resolved.description ?? '';
		accent = resolved.accent_color;
		locale = resolved.default_locale;
		listedOnInstance = resolved.listed_on_instance;
		requireRealNames = resolved.require_real_names;
	}

	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		if (!inst || !communitySlug) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolved = await fetchCommunity(inst, communitySlug);
				if (cancelled) return;
				hydrate(resolved);
			} catch (cause) {
				if (!cancelled) error = errorKind(cause);
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
		if (!instance || !community || saving) return;
		saving = true;
		saved = false;
		error = null;
		nameError = null;
		slugError = null;
		const params: CommunityParams = {
			name,
			slug,
			description,
			accent_color: accent,
			default_locale: locale as CommunityParams['default_locale'],
			listed_on_instance: listedOnInstance,
			require_real_names: requireRealNames
		};
		const oldSlug = community.slug;
		try {
			const updated = await updateCommunity(instance, oldSlug, params);
			hydrate(updated);
			saved = true;
			// A slug change renames this page's own URL: the route param (and
			// every href derived from it, like the moderation link) still says
			// the OLD slug, so a refresh or click would 404. Move to the new
			// address in place.
			if (updated.slug !== oldSlug) {
				// An aborted navigation must not read as a save failure — the
				// PUT already succeeded.
				await goto(resolve(`/i/${page.params.instance}/c/${updated.slug}/settings`), {
					replaceState: true
				}).catch(() => {});
			}
		} catch (cause) {
			// Route each 422 field onto its input; an unmapped field or a
			// non-validation failure falls to the shared banner (a `forbidden`
			// swaps in the top-level empty state, as on load).
			const keys = communityParamsErrorKeys(cause);
			nameError = keys.nameKey ? t(keys.nameKey) : null;
			slugError = keys.slugKey ? t(keys.slugKey) : null;
			error = keys.bannerKind;
		} finally {
			saving = false;
		}
	}
</script>

<svelte:head><title>{t('manage.community.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('manage.community.title')}</h1>

{#if loading}
	<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
{:else if error === 'forbidden' || (community && !canManage)}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if !community}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else}
	<form class="flex max-w-lg flex-col gap-4" onsubmit={save}>
		<Input
			id="community-name"
			label={t('manage.community.name')}
			bind:value={name}
			error={nameError}
			required
		/>
		<Input
			id="community-slug"
			label={t('manage.community.slug')}
			hint={t('manage.community.slugHint')}
			bind:value={slug}
			error={slugError}
			required
		/>

		<div class="flex flex-col gap-1.5">
			<label for="community-description" class="text-sm font-medium text-ink">
				{t('manage.community.description')}
			</label>
			<textarea
				id="community-description"
				bind:value={description}
				rows="4"
				class="rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none"
			></textarea>
		</div>

		<div class="flex items-center gap-3">
			<label for="community-accent" class="text-sm font-medium text-ink">
				{t('manage.community.accent')}
			</label>
			<input
				id="community-accent"
				type="color"
				bind:value={accent}
				class="h-9 w-14 cursor-pointer rounded-lg border border-line bg-surface"
			/>
		</div>

		<Select
			id="community-locale"
			label={t('manage.community.locale')}
			bind:value={locale}
			options={[
				{ value: 'en', label: t('manage.locale.en') },
				{ value: 'da', label: t('manage.locale.da') }
			]}
		/>

		<label class="flex items-start gap-2 text-sm text-ink">
			<input
				id="community-listed"
				type="checkbox"
				bind:checked={listedOnInstance}
				class="mt-0.5 size-4 rounded border-line text-accent focus:ring-accent"
			/>
			{t('manage.community.listedOnInstance')}
		</label>

		<div class="flex flex-col gap-1">
			<label class="flex items-start gap-2 text-sm text-ink">
				<input
					id="community-real-names"
					type="checkbox"
					bind:checked={requireRealNames}
					class="mt-0.5 size-4 rounded border-line text-accent focus:ring-accent"
				/>
				{t('manage.community.requireRealNames')}
			</label>
			<p class="pl-6 text-sm text-ink-faint">{t('manage.community.requireRealNamesHint')}</p>
		</div>

		<div class="flex items-center gap-3">
			<Button type="submit" variant="primary" disabled={saving}>
				{saving ? t('common.sending') : t('manage.community.save')}
			</Button>
			{#if saved}
				<span class="text-sm text-ink-muted" role="status">{t('manage.community.saved')}</span>
			{/if}
		</div>
		{#if error}
			<ErrorBanner kind={error} />
		{/if}
	</form>

	{#if instance}
		<CustomFieldsManager {instance} communitySlug={community.slug} />
	{/if}

	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a href={moderationHref} class="mt-6 inline-block text-sm text-accent hover:underline">
		{t('manage.moderation.link')}
	</a>
{/if}
