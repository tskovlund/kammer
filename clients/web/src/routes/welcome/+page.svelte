<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { fetchPublicCommunities } from '$lib/public/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Community } from '$lib/feed/types.js';
	import Card from '$lib/ui/Card.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The anonymous instance landing (issue #260, part of #187): the PWA
	// port of the signed-out `InstanceLive.Home` — the product-ethos blurb,
	// a sign-in affordance, and the directory of communities that opted
	// into being listed (`listed_on_instance`, SPEC §3). Visitors without
	// a signed-in instance land here from the app shell's route guard.
	// The directory section mirrors the LiveView exactly: shown only when
	// there is something to list — an empty directory, or a fetch failure
	// (e.g. the PWA served outside an instance), just leaves the ethos
	// and the sign-in button, never an error message.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let communities = $state<Community[]>([]);

	onMount(async () => {
		try {
			communities = await fetchPublicCommunities(window.location.origin);
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	function communityHref(slug: string): string {
		return resolve(`/c/${slug}`);
	}
</script>

<svelte:head><title>{t('app.name')}</title></svelte:head>

<PublicShell maxWidth="max-w-md">
	<div class="text-center">
		<p class="text-sm leading-relaxed text-ink-muted">{t('welcome.ethos')}</p>
		<a
			id="welcome-sign-in"
			href={resolve('/sign-in')}
			class="mt-6 inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-accent px-4 text-sm font-medium text-accent-ink transition-colors duration-150 hover:bg-accent/90 active:bg-accent/80"
		>
			{t('welcome.signIn')}
		</a>
	</div>

	{#if loadState === 'loading'}
		<div class="mt-10 flex flex-col gap-3" aria-busy="true">
			<Skeleton class="h-4 w-1/2" />
			<Skeleton class="h-16 w-full" />
		</div>
	{:else if communities.length > 0}
		<section class="mt-10" aria-labelledby="welcome-directory-heading">
			<h2 id="welcome-directory-heading" class="text-sm font-medium text-ink">
				{t('welcome.directory.title')}
			</h2>
			<Card class="mt-3 divide-y divide-line">
				{#each communities as community (community.id)}
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
					<a href={communityHref(community.slug)} class="block hover:bg-ink/2">
						<ListItem>
							<p class="truncate text-sm font-medium text-ink">{community.name}</p>
							{#if community.description}
								<p class="truncate text-sm text-ink-muted">{community.description}</p>
							{/if}
						</ListItem>
					</a>
				{/each}
			</Card>
		</section>
	{/if}
</PublicShell>
