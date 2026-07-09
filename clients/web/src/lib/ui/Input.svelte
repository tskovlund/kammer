<script lang="ts">
	import type { HTMLInputAttributes } from 'svelte/elements';

	interface Props extends HTMLInputAttributes {
		id: string;
		label: string;
		value?: string;
		/** Field-level error — replaces the hint and gets announced. */
		error?: string | null;
		hint?: string;
	}

	let {
		id,
		label,
		value = $bindable(''),
		error = null,
		hint,
		class: className = '',
		...rest
	}: Props = $props();
</script>

<div class="flex flex-col gap-1.5 {className}">
	<label for={id} class="text-sm font-medium text-ink">{label}</label>
	<input
		{id}
		bind:value
		class="h-11 w-full rounded-lg border bg-surface px-3 text-base text-ink transition-colors duration-150 placeholder:text-ink-faint {error
			? 'border-danger'
			: 'border-line hover:border-ink-faint/60'}"
		aria-invalid={error ? 'true' : undefined}
		aria-describedby={error ? `${id}-error` : hint ? `${id}-hint` : undefined}
		{...rest}
	/>
	{#if error}
		<p id="{id}-error" class="text-sm text-danger" role="alert">{error}</p>
	{:else if hint}
		<p id="{id}-hint" class="text-sm text-ink-faint">{hint}</p>
	{/if}
</div>
