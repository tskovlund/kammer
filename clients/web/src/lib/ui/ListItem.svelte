<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		class?: string;
		leading?: Snippet;
		trailing?: Snippet;
		children: Snippet;
	}

	let { class: className = '', leading, trailing, children }: Props = $props();
</script>

<!-- A row inside a Card list; siblings separate with hairlines via the
     parent's `divide-y divide-line`, not per-item borders. -->
<div class="flex items-center gap-3 px-4 py-3 {className}">
	{#if leading}
		<div class="shrink-0">{@render leading()}</div>
	{/if}
	<div class="min-w-0 flex-1">{@render children()}</div>
	{#if trailing}
		<div class="shrink-0">{@render trailing()}</div>
	{/if}
</div>
