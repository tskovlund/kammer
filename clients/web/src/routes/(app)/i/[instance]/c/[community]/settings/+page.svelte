<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import { updateCommunity, ManageApiError, type ManageErrorKind } from '$lib/manage/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let community = $state<Community | null>(null);
	let loading = $state(true);
	let error = $state<ManageErrorKind | null>(null);
	let saving = $state(false);
	let saved = $state(false);

	let name = $state('');
	let description = $state('');
	let accent = $state('#3E6B48');

	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);
	const moderationHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/moderation`)
	);

	$effect(() => {
		const inst = instance;
		const slug = page.params.community;
		if (!inst || !slug) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolved = await fetchCommunity(inst, slug);
				if (cancelled) return;
				community = resolved;
				name = resolved.name;
				description = resolved.description ?? '';
				accent = resolved.accent_color;
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
		if (!instance || !community || saving) return;
		saving = true;
		saved = false;
		error = null;
		try {
			const updated = await updateCommunity(instance, community.slug, {
				name,
				description,
				accent_color: accent
			});
			community = updated;
			saved = true;
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
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
		<Input id="community-name" label={t('manage.community.name')} bind:value={name} required />

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

		<div class="flex items-center gap-3">
			<Button type="submit" variant="primary" disabled={saving}>
				{saving ? t('common.sending') : t('manage.community.save')}
			</Button>
			{#if saved}
				<span class="text-sm text-ink-muted" role="status">{t('manage.community.saved')}</span>
			{/if}
			{#if error}
				<span class="text-sm text-danger" role="alert">{t('manage.error.body')}</span>
			{/if}
		</div>
	</form>

	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a href={moderationHref} class="mt-6 inline-block text-sm text-accent hover:underline">
		{t('manage.moderation.link')}
	</a>
{/if}
