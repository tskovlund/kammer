<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import * as api from '$lib/tools/api.js';
	import type { Assignment, Comment, ToolsErrorKind } from '$lib/tools/api.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let assignment = $state<Assignment | null>(null);
	let loading = $state(true);
	let loadError = $state<ToolsErrorKind | null>(null);
	let actionError = $state<ToolsErrorKind | null>(null);
	let busy = $state(false);
	let commentBody = $state('');
	let commenting = $state(false);

	const communitySlug = $derived(page.params.community!);
	const assignmentId = $derived(page.params.assignment!);

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const id = page.params.assignment;
		if (!inst || !community || !id) return;

		let cancelled = false;
		loading = true;
		loadError = null;
		assignment = null;

		(async () => {
			try {
				const resolved = await api.fetchAssignment(inst, community, id);
				if (!cancelled) assignment = resolved;
			} catch (cause) {
				if (!cancelled) loadError = cause instanceof api.ToolsApiError ? cause.kind : 'server';
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function act(run: () => Promise<void>) {
		if (!instance || busy) return;
		busy = true;
		actionError = null;
		try {
			await run();
		} catch (cause) {
			actionError = cause instanceof api.ToolsApiError ? cause.kind : 'server';
		} finally {
			busy = false;
		}
	}

	function setClaim(claimed: boolean) {
		act(async () => {
			assignment = await api.setAssignmentClaim(instance!, communitySlug, assignmentId, claimed);
		});
	}

	function setCompleted(completed: boolean) {
		act(async () => {
			assignment = await api.setAssignmentCompleted(
				instance!,
				communitySlug,
				assignmentId,
				completed
			);
		});
	}

	async function submitComment(event: SubmitEvent) {
		event.preventDefault();
		const body = commentBody.trim();
		if (body === '' || !assignment) return;
		commenting = true;
		actionError = null;
		try {
			const comment: Comment = await api.commentAssignment(instance!, communitySlug, assignmentId, {
				body_markdown: body
			});
			assignment = { ...assignment, comments: [...assignment.comments, comment] };
			commentBody = '';
		} catch (cause) {
			actionError = cause instanceof api.ToolsApiError ? cause.kind : 'server';
		} finally {
			commenting = false;
		}
	}

	const listHref = $derived(
		resolve(
			`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/assignments`
		)
	);
</script>

<svelte:head>
	<title>{assignment?.title ?? t('assignments.title')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-5">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={listHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('assignments.title')}
		</a>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3">
			<Skeleton class="h-8 w-1/2" />
			<Skeleton class="h-24" />
		</div>
	{:else if loadError === 'forbidden'}
		<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
	{:else if loadError === 'auth'}
		<EmptyState title={t('feed.error.authTitle')} body={t('feed.error.authBody')} />
	{:else if loadError || !assignment}
		<EmptyState
			title={t('assignments.detail.error.title')}
			body={t('assignments.detail.error.body')}
		/>
	{:else}
		<h1 class="text-xl font-semibold tracking-tight text-ink">{assignment.title}</h1>
		<p class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-ink-muted">
			<span
				>{assignment.completed ? t('assignments.status.done') : t('assignments.status.open')}</span
			>
			{#if assignment.due_at}
				<span>·</span>
				<span>{t('assignments.due', { date: formatDate(assignment.due_at, i18n.locale) })}</span>
			{/if}
			{#if assignment.claims.length > 0}
				<span>·</span>
				<span>
					{t('assignments.claimedBy', {
						names: assignment.claims
							.map((claim) => claim?.display_name)
							.filter((name): name is string => Boolean(name))
							.join(', ')
					})}
				</span>
			{/if}
		</p>

		<div class="mt-3 flex flex-wrap gap-2">
			{#if !assignment.completed}
				{#if assignment.claimed_by_me}
					<Button variant="ghost" size="sm" disabled={busy} onclick={() => setClaim(false)}>
						{t('assignments.unclaim')}
					</Button>
				{:else if assignment.viewer_can.includes('claim')}
					<Button variant="secondary" size="sm" disabled={busy} onclick={() => setClaim(true)}>
						{t('assignments.claim')}
					</Button>
				{/if}
				{#if assignment.viewer_can.includes('complete')}
					<Button variant="primary" size="sm" disabled={busy} onclick={() => setCompleted(true)}>
						{t('assignments.complete')}
					</Button>
				{/if}
			{:else if assignment.viewer_can.includes('reopen')}
				<Button variant="secondary" size="sm" disabled={busy} onclick={() => setCompleted(false)}>
					{t('assignments.reopen')}
				</Button>
			{/if}
		</div>

		{#if assignment.notes_markdown}
			<section class="mt-6">
				<h2 class="mb-2 text-sm font-semibold text-ink-muted">{t('assignments.detail.notes')}</h2>
				<Card class="p-4">
					<Markdown source={assignment.notes_markdown} class="text-sm" />
				</Card>
			</section>
		{/if}

		<section class="mt-6">
			<h2 class="mb-2 text-sm font-semibold text-ink-muted">
				{t('assignments.detail.discussion')}
			</h2>

			{#if actionError}
				<p class="mb-3 text-sm text-danger" role="alert">
					{actionError === 'forbidden'
						? t('manage.error.forbiddenBody')
						: t('assignments.error.body')}
				</p>
			{/if}

			{#if assignment.comments.length === 0}
				<p class="text-sm text-ink-faint">{t('assignments.comment.empty')}</p>
			{:else}
				<ul class="flex flex-col gap-3">
					{#each assignment.comments as comment (comment.id)}
						<li>
							<Card class="p-4">
								<div class="flex items-baseline justify-between gap-2">
									<span class="text-sm font-medium text-ink">
										{comment.author?.display_name ?? t('feed.author.unknown')}
									</span>
									<RelativeTime datetime={comment.inserted_at} class="text-xs" />
								</div>
								{#if comment.deleted}
									<p class="mt-1 text-sm text-ink-faint">{t('assignments.comment.removed')}</p>
								{:else}
									<Markdown source={comment.body_markdown} class="mt-1 text-sm" />
								{/if}
							</Card>
						</li>
					{/each}
				</ul>
			{/if}

			{#if assignment.viewer_can.includes('comment')}
				<form class="mt-3 flex flex-col gap-2" onsubmit={submitComment}>
					<label for="assignment-comment" class="sr-only"
						>{t('assignments.comment.placeholder')}</label
					>
					<textarea
						id="assignment-comment"
						bind:value={commentBody}
						rows="3"
						placeholder={t('assignments.comment.placeholder')}
						class="w-full rounded-lg border border-line bg-surface px-3 py-2 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
					></textarea>
					<div>
						<Button
							type="submit"
							variant="primary"
							size="sm"
							disabled={commenting || commentBody.trim() === ''}
						>
							{t('assignments.comment.submit')}
						</Button>
					</div>
				</form>
			{/if}
		</section>
	{/if}
{/if}
