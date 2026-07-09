<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { FeedApiError } from '$lib/feed/api.js';
	import { createEvent } from '$lib/events/api.js';
	import EventForm from '$lib/events/components/EventForm.svelte';
	import type { EventParams } from '$lib/events/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);
	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);

	let submitting = $state(false);
	let error = $state<string | null>(null);

	async function submit(params: EventParams): Promise<void> {
		if (!instance) return;
		submitting = true;
		error = null;
		try {
			const created = await createEvent(instance, communitySlug, groupSlug, params);
			await goto(resolve(`/i/${page.params.instance}/c/${communitySlug}/e/${created.id}`));
		} catch (cause) {
			error = cause instanceof FeedApiError ? cause.message : t('feed.error.body');
			submitting = false;
		}
	}

	function cancel(): void {
		void goto(resolve('/events'));
	}
</script>

<svelte:head><title>{t('events.form.newTitle')} · {t('app.name')}</title></svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('events.form.newTitle')}</h1>

	{#if error}
		<div
			class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
			role="alert"
		>
			{error}
		</div>
	{/if}

	<EventForm mode="create" {submitting} onSubmit={submit} onCancel={cancel} />
{/if}
