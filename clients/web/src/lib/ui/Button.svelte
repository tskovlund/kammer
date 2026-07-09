<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { HTMLButtonAttributes } from 'svelte/elements';

	interface Props extends HTMLButtonAttributes {
		variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
		size?: 'md' | 'sm';
		children: Snippet;
	}

	let {
		variant = 'secondary',
		size = 'md',
		type = 'button',
		class: className = '',
		children,
		...rest
	}: Props = $props();

	const variants = {
		primary: 'bg-accent text-accent-ink hover:bg-accent/90 active:bg-accent/80',
		secondary: 'border border-line bg-surface text-ink hover:border-ink-faint/60 active:bg-paper',
		ghost: 'text-ink-muted hover:bg-ink/5 hover:text-ink active:bg-ink/10',
		danger: 'border border-line bg-surface text-danger hover:border-danger/40 hover:bg-danger/5'
	};

	const sizes = {
		md: 'h-10 px-4 text-sm',
		sm: 'h-8 px-3 text-xs'
	};
</script>

<button
	{type}
	class="inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors duration-150 disabled:pointer-events-none disabled:opacity-50 {variants[
		variant
	]} {sizes[size]} {className}"
	{...rest}
>
	{@render children()}
</button>
