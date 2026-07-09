<script lang="ts">
	import { formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import {
		nextPollSelection,
		pollClosed,
		pollOptionPercent,
		totalPollVotes
	} from '$lib/feed/interactions.js';
	import type { Poll } from '$lib/feed/types.js';

	interface Props {
		poll: Poll;
		onVote: (optionIds: string[]) => void;
		idPrefix: string;
	}

	let { poll, onVote, idPrefix }: Props = $props();

	const closed = $derived(pollClosed(poll));
	const total = $derived(totalPollVotes(poll));

	function choose(optionId: string): void {
		if (closed) return;
		onVote(nextPollSelection(poll, optionId));
	}
</script>

<div
	class="flex flex-col gap-2 rounded-lg border border-line bg-paper/40 p-3"
	role="group"
	aria-label={t('feed.poll.label')}
>
	{#each poll.options as option (option.id)}
		{@const percent = pollOptionPercent(poll, option.id)}
		{@const chosen = poll.my_votes.includes(option.id)}
		<button
			type="button"
			id="{idPrefix}-poll-{option.id}"
			onclick={() => choose(option.id)}
			disabled={closed}
			aria-pressed={chosen}
			class="relative overflow-hidden rounded-md border px-3 py-2 text-left transition-colors duration-150 disabled:cursor-default {chosen
				? 'border-accent/50'
				: 'border-line hover:border-ink-faint/60'} {closed ? '' : 'cursor-pointer'}"
		>
			<!-- Result fill sits behind the label; width is the vote share. -->
			<span
				aria-hidden="true"
				class="absolute inset-y-0 left-0 rounded-md transition-[width] duration-300 {chosen
					? 'bg-accent/15'
					: 'bg-ink/6'}"
				style="width: {percent}%"
			></span>
			<span class="relative flex items-center justify-between gap-3">
				<span class="flex items-center gap-2 text-sm text-ink">
					<span
						aria-hidden="true"
						class="flex size-4 shrink-0 items-center justify-center rounded-full border {chosen
							? 'border-accent bg-accent text-accent-ink'
							: 'border-ink-faint/50'} {poll.multiple_choice ? 'rounded-sm' : ''}"
					>
						{#if chosen}
							<svg viewBox="0 0 16 16" fill="currentColor" class="size-3">
								<path
									d="M13.5 4.5l-7 7-4-4"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
									stroke-linecap="round"
									stroke-linejoin="round"
								/>
							</svg>
						{/if}
					</span>
					{option.text}
				</span>
				<span class="relative text-xs tabular-nums text-ink-faint">{percent}%</span>
			</span>
		</button>
	{/each}

	<p class="flex flex-wrap gap-x-2 text-xs text-ink-faint">
		<span>{t('feed.poll.votes', { count: String(total) })}</span>
		{#if poll.anonymous}
			<span>· {t('feed.poll.anonymous')}</span>
		{/if}
		{#if poll.closes_at}
			<span>
				· {closed
					? t('feed.poll.closed')
					: t('feed.poll.closes', { at: formatDateTime(poll.closes_at, i18n.locale) })}
			</span>
		{/if}
	</p>
</div>
