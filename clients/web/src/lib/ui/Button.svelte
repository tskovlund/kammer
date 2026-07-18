<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { HTMLAnchorAttributes, HTMLButtonAttributes } from 'svelte/elements';

	interface Props extends HTMLButtonAttributes {
		variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
		size?: 'md' | 'sm';
		/**
		 * Render as a link instead of a button, with the same look. Pass a
		 * `resolve()`d path — the audit (#270) flagged the hand-rolled
		 * link-as-button class copies this prop replaces.
		 */
		href?: string;
		children: Snippet;
	}

	let {
		variant = 'secondary',
		size = 'md',
		type = 'button',
		href = undefined,
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
		md: 'h-11 px-4 text-sm',
		sm: 'h-10 px-3 text-xs'
	};
</script>

{#if href}
	<!-- Callers pass resolve()'d paths; the rule can't see through the prop. -->
	<!-- eslint-disable svelte/no-navigation-without-resolve -->
	<!-- `rest` is typed for the button element (Props extends
	     HTMLButtonAttributes); on the anchor, button-only members like
	     `disabled`/`form` are inert but harmless, and the shared aria-*/
	     data-*/target/rel/title/on:* that callers actually pass forward
	     correctly. The cast keeps the spread (so those aren't dropped —
	     #316) without redesigning Props into a full polymorphic union. -->
	<a
		{href}
		{...rest as unknown as HTMLAnchorAttributes}
		class="inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors duration-150 {variants[
			variant
		]} {sizes[size]} {className}"
	>
		{@render children()}
	</a>
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
{:else}
	<button
		{type}
		class="inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors duration-150 disabled:pointer-events-none disabled:opacity-50 {variants[
			variant
		]} {sizes[size]} {className}"
		{...rest}
	>
		{@render children()}
	</button>
{/if}
