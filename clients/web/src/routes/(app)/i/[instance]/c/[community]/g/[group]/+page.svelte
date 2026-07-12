<script lang="ts">
	import { tick } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import {
		FeedApiError,
		fetchCommunity,
		fetchGroup,
		type FeedErrorKind,
		type Group
	} from '$lib/feed/api.js';
	import { createFeedStore, type FeedStore } from '$lib/feed/feed-store.svelte.js';
	import { fetchGroupCalendarToken } from '$lib/events/api.js';
	import CalendarSubscribe from '$lib/events/CalendarSubscribe.svelte';
	import Composer from '$lib/feed/components/Composer.svelte';
	import PostCard from '$lib/feed/components/PostCard.svelte';
	import type { Community } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import {
		fetchNotificationLevel,
		joinGroup,
		leaveGroup,
		setNotificationLevel
	} from '$lib/people/api.js';
	import type { NotificationLevelValue } from '$lib/people/types.js';
	import { socketStatus } from '$lib/realtime/registry.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import StaleBanner from '$lib/ui/StaleBanner.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let store = $state<FeedStore | null>(null);
	let community = $state<Community | null>(null);
	let group = $state<Group | null>(null);
	let metaError = $state<FeedErrorKind | null>(null);
	// Membership controls (#182): the caller's per-group notification
	// level (SPEC §9), and join/request/leave per `viewer_can`/`my_role`.
	let notificationLevel = $state<NotificationLevelValue | null>(null);
	let membershipBusy = $state(false);
	let membershipNotice = $state<string | null>(null);
	let heading = $state<HTMLHeadingElement>();
	// Skip the very first load: only a client-side navigation between groups
	// should pull focus to the new heading; the initial page load leaves focus
	// at the document's natural start.
	let initialLoad = true;

	const ref = $derived({ community: page.params.community!, group: page.params.group! });
	const status = $derived(instance ? socketStatus(instance.id) : 'idle');

	// Resolve community + group metadata (names, group id for the channel topic),
	// build the feed store, load the first page, and go live. Re-runs when the
	// instance or the route params change; the cleanup stops the previous feed's
	// live subscription so navigating between groups doesn't leak channels.
	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !communitySlug || !groupSlug) return;

		let cancelled = false;
		let localStore: FeedStore | null = null;
		store = null;
		community = null;
		group = null;
		metaError = null;
		notificationLevel = null;
		membershipNotice = null;

		(async () => {
			try {
				const [resolvedCommunity, resolvedGroup] = await Promise.all([
					fetchCommunity(inst, communitySlug),
					fetchGroup(inst, communitySlug, groupSlug)
				]);
				if (cancelled) return;
				community = resolvedCommunity;
				group = resolvedGroup;

				if (resolvedGroup.my_role) {
					// Best-effort: the bell selector simply stays hidden if the
					// level can't be read.
					void fetchNotificationLevel(inst, { community: communitySlug, group: groupSlug })
						.then((level) => {
							if (!cancelled) notificationLevel = level.level;
						})
						.catch(() => {});
				}
				localStore = createFeedStore(
					inst,
					{ community: communitySlug, group: groupSlug },
					resolvedGroup.id
				);
				store = localStore;
				await localStore.load();
				if (cancelled) return;
				localStore.startLive();
				// On navigation between groups, move focus to the new heading so a
				// keyboard/screen-reader user isn't stranded on the previous page's
				// context. `tick()` waits for the heading to render its new name.
				if (!initialLoad) {
					await tick();
					if (!cancelled) heading?.focus();
				}
				initialLoad = false;
			} catch (error) {
				if (!cancelled) metaError = error instanceof FeedApiError ? error.kind : 'server';
			}
		})();

		return () => {
			cancelled = true;
			localStore?.stop();
		};
	});

	async function refreshGroup(): Promise<void> {
		if (!instance || !page.params.community || !page.params.group) return;
		group = await fetchGroup(instance, page.params.community, page.params.group);
	}

	async function join(): Promise<void> {
		if (!instance) return;
		membershipBusy = true;
		membershipNotice = null;
		try {
			const outcome = await joinGroup(instance, ref);
			if (outcome === 'requested') {
				membershipNotice = t('group.joinRequested');
			} else {
				const level = await fetchNotificationLevel(instance, ref);
				notificationLevel = level.level;
			}
			await refreshGroup();
		} catch (error) {
			membershipNotice = error instanceof FeedApiError ? error.message : t('feed.error.body');
		} finally {
			membershipBusy = false;
		}
	}

	async function leave(): Promise<void> {
		if (!instance || !window.confirm(t('group.leaveConfirm'))) return;
		membershipBusy = true;
		membershipNotice = null;
		try {
			await leaveGroup(instance, ref);
			notificationLevel = null;
			membershipNotice = t('group.left');
			await refreshGroup();
		} catch (error) {
			membershipNotice = error instanceof FeedApiError ? error.message : t('feed.error.body');
		} finally {
			membershipBusy = false;
		}
	}

	async function changeLevel(level: NotificationLevelValue): Promise<void> {
		if (!instance) return;
		try {
			const next = await setNotificationLevel(instance, ref, level);
			notificationLevel = next.level;
		} catch {
			// Keep showing the last known level; the next load rereads it.
		}
	}

	const notificationLevels: NotificationLevelValue[] = [
		'everything',
		'highlights',
		'mentions_only',
		'muted'
	];

	const homeHref = resolve('/');
	const filesHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/files`)
	);
	// Collaborative-tool surfaces (issue #184), each shown only when the group
	// has the matching feature turned on (ADR 0016 feature toggles); the server
	// enforces regardless. Full path literals so SvelteKit can type-check them.
	const availabilityHref = $derived(
		resolve(
			`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/availability`
		)
	);
	const assignmentsHref = $derived(
		resolve(
			`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/assignments`
		)
	);
	const decisionsHref = $derived(
		resolve(
			`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/decisions`
		)
	);
	// Management entry points (issue #183), shown only when the group's
	// `viewer_can` grants the capability; the server enforces regardless.
	// Paths are written as full literals so SvelteKit can type-check them
	// against the known routes (a composed variable defeats that).
	const groupSettingsHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/settings`)
	);
	const moderationHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/moderation`)
	);
	const communitySettingsHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/settings`)
	);
	const canManageGroup = $derived(group?.viewer_can?.includes('manage_group') ?? false);
	const canModerate = $derived(group?.viewer_can?.includes('moderate') ?? false);
	const canManageCommunity = $derived(community?.viewer_can?.includes('manage_community') ?? false);
</script>

<svelte:head>
	<title>{group?.name ?? t('nav.groups')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')}>
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={homeHref} class="text-sm text-accent hover:underline">{t('feed.backHome')}</a>
	</EmptyState>
{:else if metaError}
	<EmptyState
		title={metaError === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
		body={metaError === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
	/>
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={homeHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{community?.name ?? t('common.back')}
		</a>
		<div class="flex items-end justify-between gap-3">
			<div class="min-w-0">
				<h1
					bind:this={heading}
					tabindex="-1"
					class="truncate text-xl font-semibold tracking-tight text-ink focus:outline-none"
				>
					{group?.name ?? ''}
				</h1>
				{#if group?.description}
					<p class="mt-0.5 line-clamp-2 text-sm text-ink-muted">{group.description}</p>
				{/if}
				{#if group?.features?.includes('files')}
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
					<a
						href={filesHref}
						class="mt-1.5 inline-flex items-center gap-1 text-sm text-accent hover:underline"
					>
						<svg
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="1.5"
							class="size-4"
						>
							<path
								stroke-linecap="round"
								stroke-linejoin="round"
								d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
							/>
						</svg>
						{t('files.link')}
					</a>
				{/if}

				{#if group?.features?.includes('availability') || group?.features?.includes('assignments') || group?.features?.includes('decisions')}
					<nav class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-sm" aria-label={t('tools.label')}>
						{#if group?.features?.includes('availability')}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={availabilityHref} class="text-accent hover:underline"
								>{t('availability.link')}</a
							>
						{/if}
						{#if group?.features?.includes('assignments')}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={assignmentsHref} class="text-accent hover:underline"
								>{t('assignments.link')}</a
							>
						{/if}
						{#if group?.features?.includes('decisions')}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={decisionsHref} class="text-accent hover:underline">{t('decisions.link')}</a>
						{/if}
					</nav>
				{/if}

				{#if group?.features?.includes('events') && instance}
					{@const inst = instance}
					<div class="mt-2">
						<CalendarSubscribe
							id="group-calendar"
							label={t('events.subscribe.groupButton')}
							load={() => fetchGroupCalendarToken(inst, ref.community, ref.group)}
						/>
					</div>
				{/if}

				<!-- Membership controls (#182), shown only when `viewer_can` /
				     `my_role` say they'd succeed — never a 403 on click. -->
				<div class="mt-2 flex flex-wrap items-center gap-3">
					{#if group && !group.my_role && (group.viewer_can.includes('join') || group.viewer_can.includes('request_to_join'))}
						<Button
							id="group-join"
							size="sm"
							variant="primary"
							disabled={membershipBusy}
							onclick={() => void join()}
						>
							{group.viewer_can.includes('join') ? t('group.join') : t('group.requestToJoin')}
						</Button>
					{/if}
					{#if group?.my_role && notificationLevel}
						<label class="flex items-center gap-2 text-sm text-ink-muted">
							<span>{t('group.notifications.label')}</span>
							<select
								id="group-notification-level"
								value={notificationLevel}
								onchange={(changeEvent) =>
									void changeLevel(changeEvent.currentTarget.value as NotificationLevelValue)}
								class="h-9 rounded-lg border border-line bg-surface px-2 text-sm text-ink"
							>
								{#each notificationLevels as level (level)}
									<option value={level}>{t(`group.notifications.${level}`)}</option>
								{/each}
							</select>
						</label>
					{/if}
					{#if group?.my_role && group.my_role !== 'owner'}
						<Button
							id="group-leave"
							size="sm"
							variant="ghost"
							disabled={membershipBusy}
							onclick={() => void leave()}
						>
							{t('group.leave')}
						</Button>
					{/if}
					{#if membershipNotice}
						<p class="text-sm text-ink-muted" role="status">{membershipNotice}</p>
					{/if}
				</div>
				{#if canManageGroup || canModerate || canManageCommunity}
					<nav
						class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-sm"
						aria-label={t('manage.moderation.title')}
					>
						{#if canManageGroup}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={groupSettingsHref} class="text-accent hover:underline"
								>{t('manage.group.title')}</a
							>
						{/if}
						{#if canModerate || canManageCommunity}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={moderationHref} class="text-accent hover:underline"
								>{t('manage.moderation.link')}</a
							>
						{/if}
						{#if canManageCommunity}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a href={communitySettingsHref} class="text-accent hover:underline"
								>{t('manage.community.title')}</a
							>
						{/if}
					</nav>
				{/if}
			</div>
			{#if store}
				<div
					class="flex shrink-0 overflow-hidden rounded-lg border border-line"
					role="group"
					aria-label={t('feed.sort.label')}
				>
					{#each [['chronological', t('feed.sort.latest')], ['activity', t('feed.sort.active')]] as const as [value, label] (value)}
						<button
							type="button"
							onclick={() => store?.setSort(value)}
							aria-pressed={store.sort === value}
							class="px-3 py-1.5 text-xs transition-colors duration-150 {store.sort === value
								? 'bg-ink/5 font-medium text-ink'
								: 'text-ink-muted hover:bg-ink/5'}"
						>
							{label}
						</button>
					{/each}
				</div>
			{/if}
		</div>

		{#if status === 'unauthorized'}
			<p class="rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
				{t('feed.reauth')}
			</p>
		{:else if status === 'reconnecting'}
			<p class="text-xs text-ink-faint">{t('feed.reconnecting')}</p>
		{/if}
	</header>

	{#if store}
		{#if store.snapshotSavedAt}
			<StaleBanner savedAt={store.snapshotSavedAt} />
		{/if}

		<div class="mb-5">
			<Composer {store} {instance} {ref} />
		</div>

		{#if store.actionError}
			<div
				class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				<span>{store.actionError.message}</span>
				<button
					type="button"
					class="shrink-0 text-danger/70 hover:text-danger"
					aria-label={t('common.dismiss')}
					onclick={() => store?.clearActionError()}
				>
					✕
				</button>
			</div>
		{/if}

		{#if store.loadState === 'loading'}
			<div class="flex flex-col gap-4">
				{#each [0, 1, 2] as skeleton (skeleton)}
					<div class="flex flex-col gap-3 rounded-xl border border-line bg-surface p-5">
						<div class="flex items-center gap-3">
							<Skeleton class="size-10 rounded-full" />
							<Skeleton class="h-4 w-32" />
						</div>
						<Skeleton class="h-4 w-full" />
						<Skeleton class="h-4 w-4/5" />
					</div>
				{/each}
			</div>
		{:else if store.loadState === 'error'}
			<EmptyState
				title={store.loadErrorKind === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
				body={store.loadErrorKind === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
			>
				<Button variant="secondary" size="sm" onclick={() => store?.load()}>
					{t('common.retry')}
				</Button>
			</EmptyState>
		{:else if store.items.length === 0}
			<EmptyState title={t('feed.empty.title')} body={t('feed.empty.body')}>
				{#snippet icon()}<TabIcon name="groups" class="size-8" />{/snippet}
			</EmptyState>
		{:else}
			<div class="flex flex-col gap-4">
				{#each store.items as post (post.id)}
					<PostCard {post} {store} {instance} currentUserId={instance.user.id} />
				{/each}
			</div>

			{#if store.hasMore}
				<div class="mt-6 flex justify-center">
					<Button
						variant="secondary"
						onclick={() => store?.loadMore()}
						disabled={store.loadingMore}
					>
						{store.loadingMore ? t('common.loading') : t('feed.loadMore')}
					</Button>
				</div>
			{/if}
		{/if}
	{/if}
{/if}
