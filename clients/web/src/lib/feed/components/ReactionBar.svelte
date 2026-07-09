<script lang="ts" module>
	// A small, calm palette — reactions are a warm nod, not a full picker.
	export const REACTION_CHOICES = ['👍', '❤️', '🎉', '😂', '🙏', '👏'];
</script>

<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { ReactionState } from '$lib/feed/interactions.js';

	interface Props {
		subject: ReactionState;
		onToggle: (emoji: string) => void;
		idPrefix: string;
	}

	let { subject, onToggle, idPrefix }: Props = $props();

	let pickerOpen = $state(false);

	// Existing reactions, most-used first, so the liveliest emoji lead.
	const entries = $derived(
		Object.entries(subject.reactions)
			.filter(([, count]) => count > 0)
			.sort((a, b) => b[1] - a[1])
	);

	function toggle(emoji: string): void {
		pickerOpen = false;
		onToggle(emoji);
	}
</script>

<div class="flex flex-wrap items-center gap-1.5">
	{#each entries as [emoji, count] (emoji)}
		{@const mine = subject.my_reactions.includes(emoji)}
		<button
			type="button"
			onclick={() => toggle(emoji)}
			aria-pressed={mine}
			class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-sm transition-colors duration-150 {mine
				? 'border-accent/40 bg-accent/10 text-accent'
				: 'border-line bg-surface text-ink-muted hover:border-ink-faint/60'}"
		>
			<span aria-hidden="true">{emoji}</span>
			<span class="tabular-nums">{count}</span>
		</button>
	{/each}

	<div class="relative">
		<button
			type="button"
			onclick={() => (pickerOpen = !pickerOpen)}
			aria-expanded={pickerOpen}
			aria-haspopup="true"
			aria-label={t('feed.react')}
			class="inline-flex size-7 items-center justify-center rounded-full border border-line text-ink-faint transition-colors duration-150 hover:border-ink-faint/60 hover:text-ink-muted"
		>
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path
					stroke-linecap="round"
					stroke-linejoin="round"
					d="M15.182 15.182a4.5 4.5 0 01-6.364 0M9 9.75h.008v.008H9V9.75zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm5.625 0h.008v.008H15V9.75zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zM21 12a9 9 0 11-18 0 9 9 0 0118 0z"
				/>
			</svg>
		</button>

		{#if pickerOpen}
			<div
				class="absolute bottom-full left-0 z-10 mb-1.5 flex gap-0.5 rounded-full border border-line bg-surface p-1 shadow-sm"
			>
				{#each REACTION_CHOICES as emoji (emoji)}
					<button
						type="button"
						id="{idPrefix}-react-{emoji}"
						onclick={() => toggle(emoji)}
						aria-pressed={subject.my_reactions.includes(emoji)}
						class="flex size-8 items-center justify-center rounded-full text-lg transition-transform duration-150 hover:scale-110 {subject.my_reactions.includes(
							emoji
						)
							? 'bg-accent/10'
							: 'hover:bg-ink/5'}"
					>
						{emoji}
					</button>
				{/each}
			</div>
		{/if}
	</div>
</div>
