<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { errorKind, type ApiErrorKind } from '$lib/api/errors.js';
	import { fetchGroup, type Group } from '$lib/feed/api.js';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import * as api from '$lib/tools/api.js';
	import type { Assignment } from '$lib/tools/api.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let group = $state<Group | null>(null);
	let assignments = $state<Assignment[]>([]);
	let loading = $state(true);
	let loadError = $state<ApiErrorKind | null>(null);
	let actionError = $state<ApiErrorKind | null>(null);
	let busy = $state<string[]>([]);

	let creating = $state(false);
	let newTitle = $state('');
	let newDue = $state('');
	let newNotes = $state('');

	const communitySlug = $derived(page.params.community!);

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !community || !groupSlug) return;

		let cancelled = false;
		loading = true;
		loadError = null;
		group = null;
		assignments = [];

		(async () => {
			try {
				const [resolvedGroup, list] = await Promise.all([
					fetchGroup(inst, community, groupSlug),
					api.fetchAssignments(inst, community, groupSlug)
				]);
				if (cancelled) return;
				group = resolvedGroup;
				assignments = list;
			} catch (cause) {
				if (!cancelled) loadError = errorKind(cause);
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	function mark(id: string, on: boolean) {
		busy = on ? [...busy, id] : busy.filter((candidate) => candidate !== id);
	}

	function replace(updated: Assignment) {
		assignments = assignments.map((item) => (item.id === updated.id ? updated : item));
	}

	async function act(id: string, run: () => Promise<void>) {
		if (!instance || busy.includes(id)) return;
		actionError = null;
		mark(id, true);
		try {
			await run();
		} catch (cause) {
			actionError = errorKind(cause);
		} finally {
			mark(id, false);
		}
	}

	function setClaim(item: Assignment, claimed: boolean) {
		act(item.id, async () => {
			replace(await api.setAssignmentClaim(instance!, communitySlug, item.id, claimed));
		});
	}

	function setCompleted(item: Assignment, completed: boolean) {
		act(item.id, async () => {
			replace(await api.setAssignmentCompleted(instance!, communitySlug, item.id, completed));
		});
	}

	function remove(item: Assignment) {
		if (!window.confirm(t('assignments.deleteConfirm'))) return;
		act(item.id, async () => {
			await api.deleteAssignment(instance!, communitySlug, item.id);
			assignments = assignments.filter((candidate) => candidate.id !== item.id);
		});
	}

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!instance) return;
		const title = newTitle.trim();
		if (title === '') return;
		await act('new', async () => {
			const created = await api.createAssignment(instance!, communitySlug, page.params.group!, {
				title,
				due_at: newDue.trim() === '' ? null : new Date(newDue).toISOString(),
				notes_markdown: newNotes.trim() === '' ? null : newNotes.trim()
			});
			assignments = [created, ...assignments];
			newTitle = '';
			newDue = '';
			newNotes = '';
			creating = false;
		});
	}

	function claimNames(item: Assignment): string {
		return item.claims
			.map((claim) => claim?.display_name)
			.filter((name): name is string => Boolean(name))
			.join(', ');
	}

	function detailHref(item: Assignment): string {
		return resolve(
			`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/assignments/${item.id}`
		);
	}

	const groupHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}`)
	);
</script>

<svelte:head>
	<title>{t('assignments.title')} · {group?.name ?? t('nav.groups')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={groupHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{group?.name ?? t('common.back')}
		</a>
		<h1 class="text-xl font-semibold tracking-tight text-ink">{t('assignments.title')}</h1>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3">
			<Skeleton class="h-20" />
			<Skeleton class="h-20" />
		</div>
	{:else if loadError === 'forbidden'}
		<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
	{:else if loadError === 'auth'}
		<EmptyState title={t('feed.error.authTitle')} body={t('feed.error.authBody')} />
	{:else if loadError}
		<EmptyState title={t('assignments.error.title')} body={t('assignments.error.body')} />
	{:else}
		{#if group?.my_role}
			<div class="mb-5">
				{#if creating}
					<Card class="p-4">
						<form class="flex flex-col gap-3" onsubmit={submit}>
							<Input
								id="assignment-title"
								label={t('assignments.new.titleLabel')}
								bind:value={newTitle}
								maxlength={200}
								required
							/>
							<label class="flex flex-col gap-1.5 text-sm font-medium text-ink">
								{t('assignments.new.dueLabel')}
								<input
									type="datetime-local"
									bind:value={newDue}
									class="h-11 w-full rounded-lg border border-line bg-surface px-3 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
								/>
							</label>
							<label class="flex flex-col gap-1.5 text-sm font-medium text-ink">
								{t('assignments.new.notesLabel')}
								<textarea
									bind:value={newNotes}
									rows="3"
									class="w-full rounded-lg border border-line bg-surface px-3 py-2 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
								></textarea>
							</label>
							<div class="flex gap-2">
								<Button type="submit" variant="primary" size="sm" disabled={busy.includes('new')}>
									{t('assignments.new.create')}
								</Button>
								<Button variant="ghost" size="sm" onclick={() => (creating = false)}>
									{t('common.cancel')}
								</Button>
							</div>
						</form>
					</Card>
				{:else}
					<Button variant="secondary" size="sm" onclick={() => (creating = true)}>
						{t('assignments.new.open')}
					</Button>
				{/if}
			</div>
		{/if}

		{#if actionError}
			<p class="mb-4 text-sm text-danger" role="alert">
				{actionError === 'forbidden'
					? t('manage.error.forbiddenBody')
					: t('assignments.error.body')}
			</p>
		{/if}

		{#if assignments.length === 0}
			<EmptyState title={t('assignments.empty.title')} body={t('assignments.empty.body')} />
		{:else}
			<ul class="flex flex-col gap-3">
				{#each assignments as item (item.id)}
					<li>
						<Card class="p-4">
							<div class="flex items-start justify-between gap-3">
								<div class="min-w-0">
									<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
									<a href={detailHref(item)} class="text-sm font-semibold text-ink hover:underline">
										{item.title}
									</a>
									<p
										class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-ink-muted"
									>
										{#if item.due_at}
											<span
												>{t('assignments.due', {
													date: formatDate(item.due_at, i18n.locale)
												})}</span
											>
										{/if}
										{#if item.claims.length > 0}
											<span>·</span>
											<span>{t('assignments.claimedBy', { names: claimNames(item) })}</span>
										{:else if !item.completed}
											<span>·</span>
											<span>{t('assignments.unclaimed')}</span>
										{/if}
										{#if item.completed && item.completed_by}
											<span>·</span>
											<span
												>{t('assignments.completedBy', {
													name: item.completed_by.display_name
												})}</span
											>
										{/if}
									</p>
								</div>
								<Chip tone={item.completed ? 'neutral' : 'accent'}>
									{item.completed ? t('assignments.status.done') : t('assignments.status.open')}
								</Chip>
							</div>

							<div class="mt-3 flex flex-wrap gap-2">
								{#if !item.completed}
									{#if item.claimed_by_me}
										<Button
											variant="ghost"
											size="sm"
											disabled={busy.includes(item.id)}
											onclick={() => setClaim(item, false)}
										>
											{t('assignments.unclaim')}
										</Button>
									{:else if item.viewer_can.includes('claim')}
										<Button
											variant="secondary"
											size="sm"
											disabled={busy.includes(item.id)}
											onclick={() => setClaim(item, true)}
										>
											{t('assignments.claim')}
										</Button>
									{/if}
									{#if item.viewer_can.includes('complete')}
										<Button
											variant="primary"
											size="sm"
											disabled={busy.includes(item.id)}
											onclick={() => setCompleted(item, true)}
										>
											{t('assignments.complete')}
										</Button>
									{/if}
								{:else if item.viewer_can.includes('reopen')}
									<Button
										variant="secondary"
										size="sm"
										disabled={busy.includes(item.id)}
										onclick={() => setCompleted(item, false)}
									>
										{t('assignments.reopen')}
									</Button>
								{/if}
								{#if item.viewer_can.includes('manage')}
									<Button
										variant="danger"
										size="sm"
										disabled={busy.includes(item.id)}
										onclick={() => remove(item)}
									>
										{t('assignments.delete')}
									</Button>
								{/if}
							</div>
						</Card>
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
{/if}
