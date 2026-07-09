<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';

	interface Props {
		onSubmit: (body: string) => Promise<boolean>;
		placeholder?: string;
		submitLabel?: string;
		initialValue?: string;
		id: string;
		compact?: boolean;
		onCancel?: () => void;
	}

	let {
		onSubmit,
		placeholder = t('feed.comment.placeholder'),
		submitLabel = t('feed.comment.submit'),
		initialValue = '',
		id,
		compact = false,
		onCancel
	}: Props = $props();

	// Seeding the field from the initial value once is intentional — the
	// composer is remounted per edit, so this never needs to react to changes.
	// svelte-ignore state_referenced_locally
	let body = $state(initialValue);
	let submitting = $state(false);

	const canSubmit = $derived(body.trim().length > 0 && !submitting);

	async function submit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (!canSubmit) return;
		submitting = true;
		const ok = await onSubmit(body.trim());
		submitting = false;
		if (ok) body = '';
	}
</script>

<form {id} onsubmit={submit} class="flex flex-col gap-2">
	<textarea
		bind:value={body}
		{placeholder}
		rows={compact ? 2 : 3}
		aria-label={placeholder}
		class="w-full resize-y rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink transition-colors duration-150 placeholder:text-ink-faint hover:border-ink-faint/60 focus-visible:border-accent"
	></textarea>
	<div class="flex items-center justify-end gap-2">
		{#if onCancel}
			<Button variant="ghost" size="sm" onclick={onCancel}>{t('common.cancel')}</Button>
		{/if}
		<Button type="submit" variant="primary" size="sm" disabled={!canSubmit}>
			{submitting ? t('common.sending') : submitLabel}
		</Button>
	</div>
</form>
