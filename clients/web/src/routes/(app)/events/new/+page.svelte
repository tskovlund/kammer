<script lang="ts">
	import { resolve } from '$app/paths';
	import { fetchCommunities, fetchGroups } from '$lib/events/api.js';
	import type { Community } from '$lib/feed/types.js';
	import type { Group } from '$lib/feed/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	interface Choice {
		instance: Instance;
		community: Community;
		group: Group;
	}

	let choices = $state<Choice[]>([]);
	let loading = $state(true);

	// Which groups a member can actually post events in isn't exposed yet
	// (#199), so we offer every group with the events feature and let the
	// create call fail closed (403) if the caller lacks the right.
	$effect(() => {
		const list = instances.list;
		loading = true;
		let cancelled = false;

		(async () => {
			const collected: Choice[] = [];
			await Promise.all(
				list.map(async (instance) => {
					try {
						const communities = await fetchCommunities(instance);
						await Promise.all(
							communities.map(async (community) => {
								try {
									const groups = await fetchGroups(instance, community.slug);
									for (const group of groups) {
										if (group.features?.includes('events')) {
											collected.push({ instance, community, group });
										}
									}
								} catch {
									/* skip an unreadable community */
								}
							})
						);
					} catch {
						/* skip an unreachable instance */
					}
				})
			);
			if (!cancelled) {
				choices = collected;
				loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	function createHref(choice: Choice): string {
		return resolve(
			`/i/${choice.instance.id}/c/${choice.community.slug}/g/${choice.group.slug}/events/new`
		);
	}
</script>

<svelte:head><title>{t('events.form.newTitle')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-1 text-xl font-semibold tracking-tight text-ink">{t('events.form.newTitle')}</h1>
<p class="mb-5 text-sm text-ink-muted">{t('events.picker.subtitle')}</p>

{#if loading}
	<div class="flex flex-col gap-2">
		{#each [0, 1, 2] as skeleton (skeleton)}
			<Skeleton class="h-14 w-full rounded-xl" />
		{/each}
	</div>
{:else if choices.length === 0}
	<EmptyState title={t('events.picker.emptyTitle')} body={t('events.picker.emptyBody')} />
{:else}
	<ul class="flex flex-col gap-2">
		{#each choices as choice (`${choice.instance.id}:${choice.group.id}`)}
			<li>
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					href={createHref(choice)}
					class="flex flex-col rounded-xl border border-line bg-surface p-3.5 transition-colors duration-150 hover:border-ink-faint/50"
				>
					<span class="font-medium text-ink">{choice.group.name}</span>
					<span class="text-sm text-ink-muted">{choice.community.name}</span>
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			</li>
		{/each}
	</ul>
{/if}
