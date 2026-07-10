<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchGroup, type Group } from '$lib/feed/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import * as api from '$lib/tools/api.js';
	import type { Decision, DecisionOutcome, ToolsErrorKind } from '$lib/tools/api.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let group = $state<Group | null>(null);
	let decisions = $state<Decision[]>([]);
	let loading = $state(true);
	let loadError = $state<ToolsErrorKind | null>(null);
	let actionError = $state<ToolsErrorKind | null>(null);
	let busy = $state<string[]>([]);

	let creating = $state(false);
	let newTitle = $state('');
	let newBody = $state('');
	let newWithVote = $state(true);

	// The decision whose outcome-recording form is open, plus its draft.
	let recordingId = $state<string | null>(null);
	let recordOutcome = $state<DecisionOutcome>('adopted');
	let recordNote = $state('');

	const communitySlug = $derived(page.params.community!);
	const outcomes: DecisionOutcome[] = ['adopted', 'rejected', 'noted'];

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !community || !groupSlug) return;

		let cancelled = false;
		loading = true;
		loadError = null;
		group = null;
		decisions = [];

		(async () => {
			try {
				const [resolvedGroup, list] = await Promise.all([
					fetchGroup(inst, community, groupSlug),
					api.fetchDecisions(inst, community, groupSlug)
				]);
				if (cancelled) return;
				group = resolvedGroup;
				decisions = list;
			} catch (cause) {
				if (!cancelled) loadError = api.toolsErrorKind(cause);
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

	async function act(id: string, run: () => Promise<void>) {
		if (!instance || busy.includes(id)) return;
		actionError = null;
		mark(id, true);
		try {
			await run();
		} catch (cause) {
			actionError = cause instanceof api.ToolsApiError ? cause.kind : 'server';
		} finally {
			mark(id, false);
		}
	}

	async function submitMotion(event: SubmitEvent) {
		event.preventDefault();
		if (!instance) return;
		const title = newTitle.trim();
		if (title === '') return;
		await act('new', async () => {
			const created = await api.createDecision(instance!, communitySlug, page.params.group!, {
				title,
				motion_markdown: newBody.trim() === '' ? null : newBody.trim(),
				with_vote: newWithVote
			});
			decisions = [created, ...decisions];
			newTitle = '';
			newBody = '';
			newWithVote = true;
			creating = false;
		});
	}

	function openRecord(decision: Decision) {
		recordingId = decision.id;
		recordOutcome = 'adopted';
		recordNote = '';
	}

	async function submitOutcome(event: SubmitEvent, decision: Decision) {
		event.preventDefault();
		await act(decision.id, async () => {
			const updated = await api.recordOutcome(instance!, communitySlug, decision.id, {
				outcome: recordOutcome,
				outcome_note: recordNote.trim() === '' ? null : recordNote.trim()
			});
			decisions = decisions.map((item) => (item.id === updated.id ? updated : item));
			recordingId = null;
		});
	}

	const groupHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}`)
	);
</script>

<svelte:head>
	<title>{t('decisions.title')} · {group?.name ?? t('nav.groups')} · {t('app.name')}</title>
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
		<h1 class="text-xl font-semibold tracking-tight text-ink">{t('decisions.title')}</h1>
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
		<EmptyState title={t('decisions.error.title')} body={t('decisions.error.body')} />
	{:else}
		{#if group?.my_role}
			<div class="mb-5">
				{#if creating}
					<Card class="p-4">
						<form class="flex flex-col gap-3" onsubmit={submitMotion}>
							<Input
								id="motion-title"
								label={t('decisions.new.titleLabel')}
								bind:value={newTitle}
								maxlength={200}
								required
							/>
							<label class="flex flex-col gap-1.5 text-sm font-medium text-ink">
								{t('decisions.new.bodyLabel')}
								<textarea
									bind:value={newBody}
									rows="3"
									class="w-full rounded-lg border border-line bg-surface px-3 py-2 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
								></textarea>
							</label>
							<label class="flex items-center gap-2 text-sm text-ink">
								<input
									type="checkbox"
									bind:checked={newWithVote}
									class="size-4 rounded border-line"
								/>
								{t('decisions.new.withVote')}
							</label>
							<div class="flex gap-2">
								<Button type="submit" variant="primary" size="sm" disabled={busy.includes('new')}>
									{t('decisions.new.create')}
								</Button>
								<Button variant="ghost" size="sm" onclick={() => (creating = false)}>
									{t('common.cancel')}
								</Button>
							</div>
						</form>
					</Card>
				{:else}
					<Button variant="secondary" size="sm" onclick={() => (creating = true)}>
						{t('decisions.new.open')}
					</Button>
				{/if}
			</div>
		{/if}

		{#if actionError}
			<p class="mb-4 text-sm text-danger" role="alert">
				{actionError === 'forbidden' ? t('manage.error.forbiddenBody') : t('decisions.error.body')}
			</p>
		{/if}

		{#if decisions.length === 0}
			<EmptyState title={t('decisions.empty.title')} body={t('decisions.empty.body')} />
		{:else}
			<ul class="flex flex-col gap-3">
				{#each decisions as decision (decision.id)}
					<li>
						<Card class="p-4">
							<div class="flex items-start justify-between gap-3">
								<div class="min-w-0">
									<h2 class="text-sm font-semibold text-ink">{decision.title}</h2>
									<p class="mt-1 flex flex-wrap items-center gap-x-2 text-xs text-ink-muted">
										<RelativeTime datetime={decision.created_at} class="text-xs" />
										{#if decision.decided && decision.decided_by}
											<span>·</span>
											<span
												>{t('decisions.decidedBy', {
													name: decision.decided_by.display_name
												})}</span
											>
										{/if}
									</p>
									{#if decision.outcome_note}
										<p class="mt-1 text-sm text-ink-muted">{decision.outcome_note}</p>
									{/if}
								</div>
								<Chip tone={decision.decided ? 'neutral' : 'accent'}>
									{decision.outcome
										? t(`decisions.outcome.${decision.outcome}`)
										: t('decisions.outcome.pending')}
								</Chip>
							</div>

							{#if !decision.decided && decision.viewer_can.includes('record_outcome')}
								{#if recordingId === decision.id}
									<form
										class="mt-3 flex flex-col gap-2 border-t border-line pt-3"
										onsubmit={(event) => submitOutcome(event, decision)}
									>
										<div
											class="flex flex-wrap gap-2"
											role="radiogroup"
											aria-label={t('decisions.record.title')}
										>
											{#each outcomes as value (value)}
												<button
													type="button"
													role="radio"
													aria-checked={recordOutcome === value}
													onclick={() => (recordOutcome = value)}
													class="rounded-lg border px-3 py-1.5 text-xs transition-colors duration-150 {recordOutcome ===
													value
														? 'border-accent/40 bg-accent/10 font-medium text-accent'
														: 'border-line text-ink-muted hover:bg-ink/5'}"
												>
													{t(`decisions.outcome.${value}`)}
												</button>
											{/each}
										</div>
										<label class="flex flex-col gap-1.5 text-sm font-medium text-ink">
											{t('decisions.record.noteLabel')}
											<textarea
												bind:value={recordNote}
												rows="2"
												class="w-full rounded-lg border border-line bg-surface px-3 py-2 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
											></textarea>
										</label>
										<div class="flex gap-2">
											<Button
												type="submit"
												variant="primary"
												size="sm"
												disabled={busy.includes(decision.id)}
											>
												{t('decisions.record.submit')}
											</Button>
											<Button variant="ghost" size="sm" onclick={() => (recordingId = null)}>
												{t('common.cancel')}
											</Button>
										</div>
									</form>
								{:else}
									<div class="mt-3">
										<Button variant="secondary" size="sm" onclick={() => openRecord(decision)}>
											{t('decisions.record.title')}
										</Button>
									</div>
								{/if}
							{/if}
						</Card>
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
{/if}
