<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Event, RsvpStatus } from '../types.js';

	interface Props {
		event: Event;
		onRsvp: (status: RsvpStatus) => void;
	}

	let { event, onRsvp }: Props = $props();

	const options: { status: RsvpStatus; label: string }[] = [
		{ status: 'yes', label: t('events.rsvp.yes') },
		{ status: 'maybe', label: t('events.rsvp.maybe') },
		{ status: 'no', label: t('events.rsvp.no') }
	];
</script>

<div class="flex flex-col gap-2">
	<p class="text-xs font-medium tracking-wide text-ink-faint uppercase">{t('events.rsvp.label')}</p>
	<div
		class="flex overflow-hidden rounded-lg border border-line"
		role="group"
		aria-label={t('events.rsvp.label')}
	>
		{#each options as option (option.status)}
			<button
				type="button"
				id="rsvp-{option.status}"
				onclick={() => onRsvp(option.status)}
				aria-pressed={event.my_rsvp === option.status}
				class="flex flex-1 items-center justify-center gap-1.5 px-3 py-2 text-sm transition-colors duration-150 {event.my_rsvp ===
				option.status
					? 'bg-accent/10 font-medium text-accent'
					: 'text-ink-muted hover:bg-ink/5'}"
			>
				{option.label}
				<span class="text-xs text-ink-faint">{event.rsvp_counts[option.status]}</span>
			</button>
		{/each}
	</div>
</div>
