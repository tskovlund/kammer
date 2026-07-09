<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		title: string;
		body?: string;
		/** Optional pictogram above the title. */
		icon?: Snippet;
		/** Optional action (a button or link) below the copy. */
		children?: Snippet;
	}

	let { title, body, icon, children }: Props = $props();
</script>

<!-- Calm empty state: whitespace does the work, no illustration noise. -->
<div class="flex flex-col items-center gap-2 px-6 py-16 text-center">
	{#if icon}
		<div class="mb-2 text-ink-faint" aria-hidden="true">{@render icon()}</div>
	{/if}
	<h2 class="text-base font-medium text-ink">{title}</h2>
	{#if body}
		<p class="max-w-xs text-sm leading-relaxed text-ink-muted">{body}</p>
	{/if}
	{#if children}
		<div class="mt-4">{@render children()}</div>
	{/if}
</div>
