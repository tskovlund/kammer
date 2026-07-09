<script lang="ts">
	import { resolve } from '$app/paths';
	import { fetchCommunities, fetchGroups } from '$lib/events/api.js';
	import type { Group } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	interface Section {
		instance: Instance;
		community: Community;
		groups: Group[];
	}

	let sections = $state<Section[] | null>(null);
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');

	// One community directory per added account (ADR 0024: community-first):
	// each instance's communities and their visible groups, loaded in
	// parallel. An unreachable account fails the tab honestly rather than
	// silently pretending its groups don't exist.
	$effect(() => {
		const list = instances.list;
		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				const perInstance = await Promise.all(
					list.map(async (instance) => {
						const communities = await fetchCommunities(instance);
						return Promise.all(
							communities.map(async (community): Promise<Section> => ({
								instance,
								community,
								groups: await fetchGroups(instance, community.slug)
							}))
						);
					})
				);
				if (cancelled) return;
				sections = perInstance.flat();
				loadState = 'ready';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	const multiInstance = $derived(instances.list.length > 1);

	function groupHref(section: Section, group: Group): string {
		return resolve(`/i/${section.instance.id}/c/${section.community.slug}/g/${group.slug}`);
	}

	function roleLabel(role: 'owner' | 'admin' | 'member'): string {
		return t(`groups.role.${role}`);
	}
</script>

<svelte:head><title>{t('nav.groups')} · {t('app.name')}</title></svelte:head>

<h1 class="text-xl font-semibold tracking-tight text-ink">{t('nav.groups')}</h1>

{#if loadState === 'loading'}
	<div class="mt-6 flex flex-col gap-4">
		{#each [0, 1] as skeleton (skeleton)}
			<div class="flex flex-col gap-3 rounded-xl border border-line bg-surface p-5">
				<Skeleton class="h-4 w-40" />
				<Skeleton class="h-4 w-full" />
				<Skeleton class="h-4 w-4/5" />
			</div>
		{/each}
	</div>
{:else if loadState === 'error'}
	<EmptyState title={t('groups.error.title')} body={t('groups.error.body')} />
{:else if !sections || sections.length === 0}
	<EmptyState title={t('groups.empty.title')} body={t('groups.empty.body')}>
		{#snippet icon()}<TabIcon name="groups" class="size-8" />{/snippet}
	</EmptyState>
{:else}
	<div class="mt-6 flex flex-col gap-8">
		{#each sections as section (section.instance.id + section.community.id)}
			<section aria-labelledby="community-{section.instance.id}-{section.community.id}">
				<div class="flex flex-wrap items-baseline justify-between gap-2">
					<h2
						id="community-{section.instance.id}-{section.community.id}"
						class="text-sm font-medium text-ink"
					>
						{section.community.name}
						{#if multiInstance}
							<span class="font-normal text-ink-faint">· {section.instance.instanceName}</span>
						{/if}
					</h2>
					<div class="flex gap-4 text-sm">
						{#if section.community.viewer_can.includes('view_member_directory')}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a
								href={resolve(`/i/${section.instance.id}/c/${section.community.slug}/members`)}
								class="text-accent hover:underline"
							>
								{t('groups.members')}
							</a>
						{/if}
						{#if section.community.viewer_can.includes('manage_community')}
							<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
							<a
								href={resolve(`/i/${section.instance.id}/c/${section.community.slug}/invites`)}
								class="text-accent hover:underline"
							>
								{t('groups.invites')}
							</a>
						{/if}
					</div>
				</div>

				<Card class="mt-3 divide-y divide-line">
					{#each section.groups as group (group.id)}
						<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
						<a href={groupHref(section, group)} class="block hover:bg-ink/2">
							<ListItem>
								<p class="truncate text-sm font-medium text-ink">{group.name}</p>
								{#if group.description}
									<p class="truncate text-sm text-ink-muted">{group.description}</p>
								{/if}
								{#snippet trailing()}
									<span class="flex items-center gap-1.5">
										{#if group.archived}
											<Chip>{t('groups.archived')}</Chip>
										{/if}
										{#if group.my_role}
											<Chip tone={group.my_role === 'member' ? 'neutral' : 'accent'}>
												{roleLabel(group.my_role)}
											</Chip>
										{/if}
									</span>
								{/snippet}
							</ListItem>
						</a>
					{/each}
				</Card>
			</section>
		{/each}
	</div>
{/if}
