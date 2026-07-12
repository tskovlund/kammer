<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError, errorKind, type ApiErrorKind } from '$lib/api/errors.js';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import {
		createBan,
		dismissReport,
		fetchBans,
		fetchReports,
		liftBan,
		resolveReport,
		type Ban,
		type Report
	} from '$lib/manage/api.js';
	import { fetchRoster } from '$lib/people/api.js';
	import type { Member } from '$lib/people/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let community = $state<Community | null>(null);
	let reports = $state<Report[]>([]);
	let bans = $state<Ban[]>([]);
	let members = $state<Member[]>([]);
	let loading = $state(true);
	// Load failure — replaces the page. A per-action failure uses
	// `actionError` instead, so one failed resolve/dismiss doesn't discard
	// the whole loaded queue.
	let error = $state<ApiErrorKind | null>(null);
	let actionError = $state<ApiErrorKind | null>(null);
	// Ids currently mid-action, so their buttons disable without freezing the
	// whole list.
	let busy = $state<string[]>([]);

	// Ban-creation form (SPEC §11): the target must be picked from the
	// roster, so only admins (who fetch it) see the form at all.
	let banUserId = $state('');
	let banReason = $state('');
	let banning = $state(false);
	let banError = $state<string | null>(null);

	const communitySlug = $derived(page.params.community!);
	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);

	// Only plain members can be banned — the server refuses admins and
	// owners (demote first, deliberately two steps) and self-bans.
	const banCandidates = $derived(
		members.filter((member) => member.role === 'member' && member.user.id !== instance?.user.id)
	);

	$effect(() => {
		const inst = instance;
		const slug = page.params.community;
		if (!inst || !slug) return;

		let cancelled = false;
		loading = true;
		error = null;
		// A re-run means a different community (or a refreshed instance
		// list) — the ban form must not carry a selection, typed reason,
		// error, or in-flight lock across (a stale selection would leave
		// the Ban button enabled while onBan silently no-ops).
		banUserId = '';
		banReason = '';
		banError = null;
		banning = false;

		(async () => {
			try {
				const resolvedCommunity = await fetchCommunity(inst, slug);
				if (cancelled) return;
				community = resolvedCommunity;
				const manage = resolvedCommunity.viewer_can.includes('manage_community');
				const [resolvedReports, resolvedBans, resolvedRoster] = await Promise.all([
					fetchReports(inst, slug),
					fetchBans(inst, slug),
					// The roster only feeds the ban form, which only admins see.
					manage ? fetchRoster(inst, slug) : Promise.resolve(null)
				]);
				if (cancelled) return;
				reports = resolvedReports;
				bans = resolvedBans;
				members = resolvedRoster?.members ?? [];
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
			actionError = errorKind(cause);
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

	async function onBan(event: SubmitEvent) {
		event.preventDefault();
		const target = banCandidates.find((candidate) => candidate.user.id === banUserId);
		if (!instance || !target || banning) return;
		if (!window.confirm(t('manage.moderation.ban.confirm', { name: target.user.display_name })))
			return;
		// A POST that resolves after the admin navigated to ANOTHER
		// community's moderation page must not touch its state — unlike the
		// act() handlers (whose filters no-op harmlessly), a prepend would
		// plant this community's ban row in the other list. The load effect
		// owns the reset on navigation; a stale settle changes nothing.
		const submittedTo = `${instance.id}/${communitySlug}`;
		const stale = () => `${instance?.id}/${communitySlug}` !== submittedTo;
		banning = true;
		banError = null;
		try {
			const ban = await createBan(
				instance,
				communitySlug,
				target.user.id,
				banReason.trim() || null
			);
			if (stale()) return;
			bans = [ban, ...bans];
			members = members.filter((candidate) => candidate.user.id !== target.user.id);
			banUserId = '';
			banReason = '';
		} catch (cause) {
			if (stale()) return;
			// A 422's field names key our own copy — the server's English
			// message never renders (#253). `email` means the address already
			// carries a ban; `reason` is the 2000-character cap.
			if (cause instanceof ApiError && cause.kind === 'validation' && cause.details.email) {
				banError = t('manage.moderation.ban.errorAlreadyBanned');
			} else if (cause instanceof ApiError && cause.kind === 'validation' && cause.details.reason) {
				banError = t('manage.moderation.ban.errorReason');
			} else {
				banError = t('manage.error.body');
			}
		} finally {
			if (!stale()) banning = false;
		}
	}

	const backHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/settings`)
	);
	const auditHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/moderation/audit`)
	);
</script>

<svelte:head><title>{t('manage.moderation.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('manage.moderation.title')}</h1>

{#if loading}
	<div class="flex flex-col gap-3">
		<Skeleton class="h-24" />
		<Skeleton class="h-24" />
	</div>
{:else if error === 'forbidden'}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if error}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else}
	{#if actionError}
		<p class="mb-4 text-sm text-danger" role="alert">{t('manage.error.body')}</p>
	{/if}
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

		{#if canManage && banCandidates.length > 0}
			<form class="mt-4 flex max-w-lg flex-col gap-3" onsubmit={onBan}>
				<h3 class="text-sm font-medium text-ink">{t('manage.moderation.ban.title')}</h3>
				<Select
					id="ban-member"
					label={t('manage.moderation.ban.member')}
					bind:value={banUserId}
					options={[
						{ value: '', label: t('manage.moderation.ban.choose') },
						...banCandidates.map((candidate) => ({
							value: candidate.user.id,
							label: candidate.user.display_name
						}))
					]}
				/>
				<Input
					id="ban-reason"
					label={t('manage.moderation.ban.reason')}
					bind:value={banReason}
					maxlength={2000}
				/>
				<div class="flex items-center gap-3">
					<Button type="submit" variant="danger" disabled={banning || banUserId === ''}>
						{t('manage.moderation.ban.submit')}
					</Button>
					{#if banError}
						<span class="text-sm text-danger" role="alert">{banError}</span>
					{/if}
				</div>
			</form>
		{/if}
	</section>

	{#if canManage}
		<div class="mt-6 flex flex-col items-start gap-2">
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
			<a href={auditHref} class="text-sm text-accent hover:underline">
				{t('manage.moderation.audit.link')}
			</a>
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
			<a href={backHref} class="text-sm text-accent hover:underline">
				{t('manage.community.link')}
			</a>
		</div>
	{/if}
{/if}
