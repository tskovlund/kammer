<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import {
		dismissReport,
		fetchBans,
		fetchReports,
		liftBan,
		resolveReport,
		ManageApiError,
		type Ban,
		type ManageErrorKind,
		type Report
	} from '$lib/manage/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let community = $state<Community | null>(null);
	let reports = $state<Report[]>([]);
	let bans = $state<Ban[]>([]);
	let loading = $state(true);
	let error = $state<ManageErrorKind | null>(null);
	// Ids currently mid-action, so their buttons disable without freezing the
	// whole list.
	let busy = $state<string[]>([]);

	const communitySlug = $derived(page.params.community!);
	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);

	$effect(() => {
		const inst = instance;
		const slug = page.params.community;
		if (!inst || !slug) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolvedCommunity = await fetchCommunity(inst, slug);
				if (cancelled) return;
				community = resolvedCommunity;
				const [resolvedReports, resolvedBans] = await Promise.all([
					fetchReports(inst, slug),
					fetchBans(inst, slug)
				]);
				if (cancelled) return;
				reports = resolvedReports;
				bans = resolvedBans;
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

	function mark(id: string, on: boolean) {
		busy = on ? [...busy, id] : busy.filter((candidate) => candidate !== id);
	}

	async function act(id: string, run: () => Promise<void>) {
		if (!instance || busy.includes(id)) return;
		mark(id, true);
		try {
			await run();
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
		} finally {
			mark(id, false);
		}
	}

	function onResolve(report: Report) {
		act(report.id, async () => {
			await resolveReport(instance!, communitySlug, report.id);
			reports = reports.filter((candidate) => candidate.id !== report.id);
		});
	}

	function onDismiss(report: Report) {
		act(report.id, async () => {
			await dismissReport(instance!, communitySlug, report.id);
			reports = reports.filter((candidate) => candidate.id !== report.id);
		});
	}

	function onLift(ban: Ban) {
		act(ban.id, async () => {
			await liftBan(instance!, communitySlug, ban.id);
			bans = bans.filter((candidate) => candidate.id !== ban.id);
		});
	}

	const backHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/settings`)
	);
</script>

<svelte:head><title>{t('manage.moderation.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('manage.moderation.title')}</h1>

{#if loading}
	<div class="flex flex-col gap-3">
		<Skeleton class="h-24" />
		<Skeleton class="h-24" />
	</div>
{:else if error === 'forbidden' || (!loading && community && !canManage && bans.length === 0 && reports.length === 0)}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if error}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else}
	<section aria-labelledby="reports-heading" class="mb-8">
		<h2 id="reports-heading" class="mb-2 text-sm font-semibold text-ink-muted">
			{t('manage.moderation.reports.title')}
		</h2>
		{#if reports.length === 0}
			<EmptyState title={t('manage.moderation.reports.empty')} />
		{:else}
			<ul class="flex flex-col gap-3">
				{#each reports as report (report.id)}
					<li>
						<Card class="p-4">
							<p class="text-sm font-medium text-ink">
								{report.subject?.type === 'comment'
									? t('manage.moderation.reports.comment')
									: t('manage.moderation.reports.post')}
							</p>
							{#if report.subject?.body_markdown}
								<p class="mt-1 line-clamp-3 text-sm text-ink-muted">
									{report.subject.body_markdown}
								</p>
							{/if}
							<p class="mt-2 text-xs text-ink-faint">
								{t('manage.moderation.reports.reason', { reason: report.reason })}
							</p>
							{#if report.reporter?.display_name}
								<p class="text-xs text-ink-faint">
									{t('manage.moderation.reports.by', { name: report.reporter.display_name })}
								</p>
							{/if}
							<div class="mt-3 flex gap-2">
								<Button
									size="sm"
									variant="danger"
									disabled={busy.includes(report.id)}
									onclick={() => onResolve(report)}
								>
									{t('manage.moderation.reports.remove')}
								</Button>
								<Button
									size="sm"
									disabled={busy.includes(report.id)}
									onclick={() => onDismiss(report)}
								>
									{t('manage.moderation.reports.dismiss')}
								</Button>
							</div>
						</Card>
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	<section aria-labelledby="bans-heading">
		<h2 id="bans-heading" class="mb-2 text-sm font-semibold text-ink-muted">
			{t('manage.moderation.bans.title')}
		</h2>
		{#if bans.length === 0}
			<EmptyState title={t('manage.moderation.bans.empty')} />
		{:else}
			<Card class="divide-y divide-line">
				{#each bans as ban (ban.id)}
					<div class="flex items-center gap-3 px-4 py-3">
						<div class="min-w-0 flex-1">
							<p class="truncate text-sm font-medium text-ink">{ban.email}</p>
							{#if ban.banned_by?.display_name}
								<p class="text-xs text-ink-faint">
									{t('manage.moderation.bans.by', { name: ban.banned_by.display_name })}
								</p>
							{/if}
						</div>
						<Button size="sm" disabled={busy.includes(ban.id)} onclick={() => onLift(ban)}>
							{t('manage.moderation.bans.lift')}
						</Button>
					</div>
				{/each}
			</Card>
		{/if}
	</section>

	{#if canManage}
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="mt-6 inline-block text-sm text-accent hover:underline">
			{t('manage.community.link')}
		</a>
	{/if}
{/if}
