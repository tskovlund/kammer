<script lang="ts">
	import { page } from '$app/state';
	import { fetchGroup } from '$lib/feed/api.js';
	import {
		setGroupArchived,
		setGroupFeatures,
		updateGroup,
		ManageApiError,
		type GroupFeature,
		type ManageErrorKind
	} from '$lib/manage/api.js';
	import type { Group } from '$lib/feed/api.js';
	import type { MessageKey } from '$lib/i18n/format.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The feed is always on and can't be toggled (ADR 0016); only these five
	// are member-facing switches.
	const TOGGLEABLE = ['events', 'files', 'availability', 'assignments', 'decisions'] as const;
	const FEATURE_LABEL: Record<(typeof TOGGLEABLE)[number], MessageKey> = {
		events: 'manage.group.features.events',
		files: 'manage.group.features.files',
		availability: 'manage.group.features.availability',
		assignments: 'manage.group.features.assignments',
		decisions: 'manage.group.features.decisions'
	};

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let group = $state<Group | null>(null);
	let loading = $state(true);
	let error = $state<ManageErrorKind | null>(null);
	let saving = $state(false);
	let saved = $state(false);

	let name = $state('');
	let description = $state('');

	const canManage = $derived(group?.viewer_can.includes('manage_group') ?? false);
	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);

	$effect(() => {
		const inst = instance;
		if (!inst || !page.params.community || !page.params.group) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolved = await fetchGroup(inst, page.params.community!, page.params.group!);
				if (cancelled) return;
				group = resolved;
				name = resolved.name;
				description = resolved.description ?? '';
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

	async function run<T>(work: () => Promise<T>) {
		if (!instance || saving) return;
		saving = true;
		saved = false;
		error = null;
		try {
			await work();
			saved = true;
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
		} finally {
			saving = false;
		}
	}

	function saveDetails(event: SubmitEvent) {
		event.preventDefault();
		run(async () => {
			group = await updateGroup(instance!, communitySlug, groupSlug, { name, description });
		});
	}

	function toggleFeature(feature: GroupFeature, on: boolean) {
		const current = group;
		if (!current) return;
		// The feed is forced on and never toggled (ADR 0016); rebuild the list
		// in canonical order from the toggleable set.
		const next: GroupFeature[] = [
			'feed',
			...TOGGLEABLE.filter((candidate) =>
				candidate === feature ? on : current.features.includes(candidate)
			)
		];
		run(async () => {
			group = await setGroupFeatures(instance!, communitySlug, groupSlug, next);
		});
	}

	function toggleArchived() {
		if (!group) return;
		const archived = group.archived;
		run(async () => {
			group = await setGroupArchived(instance!, communitySlug, groupSlug, !archived);
		});
	}
</script>

<svelte:head><title>{t('manage.group.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('manage.group.title')}</h1>

{#if loading}
	<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
{:else if error === 'forbidden' || (group && !canManage)}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if !group}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else}
	{#if group.archived}
		<p class="mb-4 rounded-lg border border-line bg-paper px-3 py-2 text-sm text-ink-muted">
			{t('manage.group.archived')}
		</p>
	{/if}

	<form class="flex max-w-lg flex-col gap-4" onsubmit={saveDetails}>
		<Input id="group-name" label={t('manage.group.name')} bind:value={name} required />

		<div class="flex flex-col gap-1.5">
			<label for="group-description" class="text-sm font-medium text-ink">
				{t('manage.group.description')}
			</label>
			<textarea
				id="group-description"
				bind:value={description}
				rows="3"
				class="rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none"
			></textarea>
		</div>

		<div class="flex items-center gap-3">
			<Button type="submit" variant="primary" disabled={saving}>
				{saving ? t('common.sending') : t('manage.group.save')}
			</Button>
			{#if saved}
				<span class="text-sm text-ink-muted" role="status">{t('manage.group.saved')}</span>
			{/if}
			{#if error}
				<span class="text-sm text-danger" role="alert">{t('manage.error.body')}</span>
			{/if}
		</div>
	</form>

	<section aria-labelledby="features-heading" class="mt-8 max-w-lg">
		<h2 id="features-heading" class="mb-2 text-sm font-semibold text-ink-muted">
			{t('manage.group.features.title')}
		</h2>
		<div class="flex flex-col gap-2">
			{#each TOGGLEABLE as feature (feature)}
				<label class="flex items-center gap-2 text-sm text-ink">
					<input
						type="checkbox"
						checked={group.features.includes(feature)}
						disabled={saving}
						onchange={(event) => toggleFeature(feature, event.currentTarget.checked)}
						class="size-4 rounded border-line text-accent focus:ring-accent"
					/>
					{t(FEATURE_LABEL[feature])}
				</label>
			{/each}
		</div>
	</section>

	<div class="mt-8 max-w-lg">
		<Button variant="danger" disabled={saving} onclick={toggleArchived}>
			{group.archived ? t('manage.group.unarchive') : t('manage.group.archive')}
		</Button>
	</div>
{/if}
