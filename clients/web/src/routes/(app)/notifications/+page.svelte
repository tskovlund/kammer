<script lang="ts">
	import { resolve } from '$app/paths';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import {
		createNotificationsStore,
		type MergedNotification
	} from '$lib/notifications/notifications-store.svelte.js';
	import { notificationTarget } from '$lib/notifications/target.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import FailedInstancesBanner from '$lib/ui/FailedInstancesBanner.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const notifications = createNotificationsStore();

	$effect(() => {
		const list = instances.list;
		notifications.load(list);
		return () => notifications.stop();
	});

	// What happened, in the viewer's words — mirrors NotificationLive.Index's
	// `describe/1`. The serializer already resolves group-authored posts to a
	// group actor (#167), so `actor.display_name` covers that case too.
	function describe(notification: MergedNotification): string {
		const name = notification.actor?.display_name ?? t('feed.author.unknown');
		switch (notification.kind) {
			case 'mention':
				return t('notifications.kind.mention', { name });
			case 'reply':
				return t('notifications.kind.reply', { name });
			case 'acknowledgment_required':
				return t('notifications.kind.ack', { name });
			case 'event_created':
				return t('notifications.kind.eventCreated', { name });
			case 'event_reminder':
				return t('notifications.kind.eventReminder');
			case 'event_promoted':
				return t('notifications.kind.eventPromoted');
			default:
				return t('notifications.kind.post', { name });
		}
	}

	function href(notification: MergedNotification): string {
		return resolve(notificationTarget(notification, notification.instance.id) ?? '/');
	}
</script>

<svelte:head><title>{t('nav.notifications')} · {t('app.name')}</title></svelte:head>

<div class="mb-5 flex items-center justify-between gap-3">
	<h1 class="text-xl font-semibold tracking-tight text-ink">{t('nav.notifications')}</h1>
	{#if notifications.unreadCount > 0 || notifications.hasMore}
		<button
			type="button"
			id="notifications-mark-all-read"
			onclick={() => notifications.markAllRead()}
			disabled={notifications.markingAll}
			class="shrink-0 rounded-lg border border-line bg-surface px-3 py-1.5 text-sm font-medium text-ink transition-colors duration-150 hover:border-ink-faint/60 disabled:opacity-60"
		>
			{t('notifications.markAllRead')}
		</button>
	{/if}
</div>

<FailedInstancesBanner
	failures={notifications.failedInstances}
	onRetry={() => notifications.load(instances.list)}
/>

{#if notifications.loadState === 'loading' && notifications.isEmpty}
	<div class="flex flex-col gap-2">
		{#each [0, 1, 2] as skeleton (skeleton)}
			<div class="flex items-center gap-3 rounded-xl border border-line bg-surface p-3.5">
				<Skeleton class="size-8 rounded-full" />
				<div class="flex flex-1 flex-col gap-2">
					<Skeleton class="h-3.5 w-48" />
					<Skeleton class="h-3 w-32" />
				</div>
			</div>
		{/each}
	</div>
{:else if notifications.loadState === 'error'}
	<EmptyState title={t('notifications.error.title')} body={t('notifications.error.body')} />
{:else if notifications.isEmpty}
	<EmptyState title={t('notifications.empty.title')} body={t('notifications.empty.body')}>
		{#snippet icon()}<TabIcon name="notifications" class="size-8" />{/snippet}
	</EmptyState>
{:else}
	<ul class="flex flex-col gap-1">
		{#each notifications.items as notification (`${notification.instance.id}:${notification.id}`)}
			<li>
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					id="notification-{notification.instance.id}-{notification.id}"
					href={href(notification)}
					onclick={() => notifications.markRead(notification)}
					class="flex items-start gap-3 rounded-xl px-3 py-2.5 transition-colors duration-150 hover:bg-ink/5 {notification.read
						? ''
						: 'bg-accent/5'}"
				>
					<Avatar author={notification.actor} size="sm" />
					<div class="min-w-0 flex-1">
						<p class="text-sm {notification.read ? 'text-ink-muted' : 'font-medium text-ink'}">
							{describe(notification)}
						</p>
						<p class="mt-0.5 flex flex-wrap items-baseline gap-x-1.5 text-xs text-ink-faint">
							{#if notification.community}
								<span class="truncate">{notification.community.name}</span>
							{/if}
							{#if notification.group}
								{#if notification.community}<span aria-hidden="true">·</span>{/if}
								<span class="truncate">{notification.group.name}</span>
							{/if}
							{#if notification.community || notification.group}<span aria-hidden="true">·</span
								>{/if}
							<RelativeTime datetime={notification.inserted_at} class="text-xs" />
						</p>
					</div>
					{#if !notification.read}
						<span class="mt-1.5 size-2 shrink-0 rounded-full bg-accent" aria-hidden="true"></span>
						<span class="sr-only">{t('notifications.unread')}</span>
					{/if}
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			</li>
		{/each}
	</ul>
	{#if notifications.hasMore}
		<div class="mt-4 flex justify-center">
			<button
				type="button"
				id="notifications-load-more"
				onclick={() => notifications.loadMore()}
				disabled={notifications.loadingMore}
				class="rounded-lg border border-line bg-surface px-4 py-2 text-sm font-medium text-ink transition-colors duration-150 hover:border-ink-faint/60 disabled:opacity-60"
			>
				{notifications.loadingMore ? t('common.loading') : t('notifications.loadMore')}
			</button>
		</div>
	{/if}
{/if}
