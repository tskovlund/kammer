<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchPublicCommunity, type PublicCommunity } from '$lib/public/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The tokenless public community page (issue #185 slice B): a
	// community's public face and its `public_listed` groups — the same
	// content `CommunityLive.Home` shows an anonymous visitor, over the PWA
	// instead. `public_link` groups stay reachable directly by URL (the
	// group page below) but aren't listed here, same as the LiveView page
	// and the RSS feed — that's what "unlisted" means.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let data = $state<PublicCommunity | null>(null);

	onMount(async () => {
		try {
			data = await fetchPublicCommunity(window.location.origin, page.params.community!);
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	function groupHref(groupSlug: string): string {
		return resolve(`/c/${page.params.community}/g/${groupSlug}`);
	}
</script>

<svelte:head>
	<title>{data ? data.community.name : t('public.community.loading')} · {t('app.name')}</title>
</svelte:head>

<PublicShell maxWidth="max-w-2xl">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('public.community.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-6 w-2/3" />
				<Skeleton class="h-20 w-full" />
			</div>
		</div>
	{:else if loadState === 'error' || !data}
		<EmptyState title={t('public.community.error.title')} body={t('public.community.error.body')} />
	{:else}
		<h1 class="text-xl font-semibold tracking-tight text-ink">{data.community.name}</h1>
		{#if data.community.description}
			<Markdown source={data.community.description} class="mt-3" />
		{/if}

		{#if data.groups.length === 0}
			<p class="mt-8 text-sm text-ink-muted">{t('public.community.groups.empty')}</p>
		{:else}
			<Card class="mt-8 divide-y divide-line">
				{#each data.groups as group (group.id)}
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
					<a href={groupHref(group.slug)} class="block hover:bg-ink/2">
						<ListItem>
							<p class="truncate text-sm font-medium text-ink">{group.name}</p>
							{#if group.description}
								<p class="truncate text-sm text-ink-muted">{group.description}</p>
							{/if}
						</ListItem>
					</a>
				{/each}
			</Card>
		{/if}
	{/if}
</PublicShell>
