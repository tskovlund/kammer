<script lang="ts">
	import { resolve } from '$app/paths';
	import { formatDate, formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import type { MergedEvent } from '$lib/instances/home.js';

	interface Props {
		event: MergedEvent;
	}

	let { event }: Props = $props();

	const href = $derived(
		resolve(`/i/${event.instance.id}/c/${event.community.slug}/g/${event.group.slug}`)
	);

	const when = $derived(
		event.all_day
			? formatDate(event.starts_at, i18n.locale)
			: formatDateTime(event.starts_at, i18n.locale)
	);
</script>

<!-- eslint-disable svelte/no-navigation-without-resolve -->
<a
	{href}
	class="flex items-center gap-3 rounded-xl border border-line bg-surface p-3.5 transition-colors duration-150 hover:border-ink-faint/50"
>
	<div
		class="flex size-11 shrink-0 flex-col items-center justify-center rounded-lg bg-accent/8 text-accent"
		aria-hidden="true"
	>
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-5">
			<path
				stroke-linecap="round"
				stroke-linejoin="round"
				d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 7.5v11.25m-18 0A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75m-18 0v-7.5A2.25 2.25 0 015.25 9h13.5A2.25 2.25 0 0121 11.25v7.5"
			/>
		</svg>
	</div>
	<div class="min-w-0 flex-1">
		<p class="truncate font-medium text-ink">{event.title}</p>
		<p class="flex flex-wrap items-baseline gap-x-2 text-sm text-ink-muted">
			<span>{when}</span>
			<span class="text-ink-faint">·</span>
			<span class="truncate">{event.group.name}</span>
		</p>
	</div>
	{#if event.my_rsvp === 'yes'}
		<span class="shrink-0 text-xs font-medium text-accent">{t('home.rsvpGoing')}</span>
	{/if}
</a>
<!-- eslint-enable svelte/no-navigation-without-resolve -->
