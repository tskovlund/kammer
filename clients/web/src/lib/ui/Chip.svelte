<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		/** `accent` marks provenance (e.g. which community an item came from). */
		tone?: 'neutral' | 'accent';
		class?: string;
		children: Snippet;
	}

	let { tone = 'neutral', class: className = '', children }: Props = $props();

	const tones = {
		neutral: 'border-line bg-paper text-ink-muted',
		accent: 'border-accent/25 bg-accent/5 text-accent'
	};
</script>

<span
	class="inline-flex max-w-full items-center gap-1 truncate rounded-full border px-2.5 py-0.5 text-xs {tones[
		tone
	]} {className}"
>
	{@render children()}
</span>
