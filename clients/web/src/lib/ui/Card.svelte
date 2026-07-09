<script lang="ts">
	import type { Snippet } from 'svelte';

	interface Props {
		class?: string;
		children: Snippet;
	}

	let { class: className = '', children }: Props = $props();
</script>

<!-- Quiet surface: hairline border, no shadow (SPEC.md §21). -->
<div class="rounded-xl border border-line bg-surface {className}">
	{@render children()}
</div>
