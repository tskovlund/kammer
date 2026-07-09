<script lang="ts">
	import type { Author } from '$lib/feed/types.js';

	interface Props {
		/** Serializer authors are optional (deleted authors serialize to null). */
		author: Author | undefined;
		fallback?: string;
		size?: 'sm' | 'md';
		class?: string;
	}

	let { author, fallback = '?', size = 'md', class: className = '' }: Props = $props();

	const name = $derived(author?.display_name ?? fallback);
	const isGroup = $derived(author?.type === 'group');

	// Initials from the display name: up to two leading letters of the first
	// two words, so "The Band" → "TB", "Alice" → "A".
	const initials = $derived(
		name
			.split(/\s+/)
			.filter(Boolean)
			.slice(0, 2)
			.map((word) => word[0]?.toUpperCase() ?? '')
			.join('') || fallback[0]?.toUpperCase()
	);

	const sizes = { sm: 'size-8 text-xs', md: 'size-10 text-sm' };
</script>

<!-- A group posting "as the group" reads as the community's voice, so its
     avatar takes the accent tint; humans and guests stay neutral. -->
<span
	aria-hidden="true"
	class="inline-flex shrink-0 items-center justify-center rounded-full font-medium {sizes[
		size
	]} {isGroup ? 'bg-accent/12 text-accent' : 'bg-ink/8 text-ink-muted'} {className}"
>
	{initials}
</span>
