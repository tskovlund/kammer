<script lang="ts">
	import type { HTMLSelectAttributes } from 'svelte/elements';

	interface Option {
		value: string;
		label: string;
	}

	interface Props extends HTMLSelectAttributes {
		id: string;
		label: string;
		options: Option[];
		value?: string;
		hint?: string;
	}

	let {
		id,
		label,
		options,
		value = $bindable(''),
		hint,
		class: className = '',
		...rest
	}: Props = $props();
</script>

<div class="flex flex-col gap-1.5 {className}">
	<label for={id} class="text-sm font-medium text-ink">{label}</label>
	<select
		{id}
		bind:value
		class="h-11 w-full rounded-lg border border-line bg-surface px-3 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
		aria-describedby={hint ? `${id}-hint` : undefined}
		{...rest}
	>
		{#each options as option (option.value)}
			<option value={option.value}>{option.label}</option>
		{/each}
	</select>
	{#if hint}
		<p id="{id}-hint" class="text-sm text-ink-faint">{hint}</p>
	{/if}
</div>
