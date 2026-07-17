<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { type ApiErrorKind } from '$lib/api/errors.js';
	import { createEvent, eventParamsErrorKeys } from '$lib/events/api.js';
	import EventForm from '$lib/events/components/EventForm.svelte';
	import type { EventFieldErrors, EventParams } from '$lib/events/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ErrorBanner from '$lib/ui/ErrorBanner.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);
	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);

	let submitting = $state(false);
	let bannerKind = $state<ApiErrorKind | null>(null);
	// Per-field 422 copy, keyed on the Event changeset field names, never the
	// server's English strings (#253).
	let fieldErrors = $state<EventFieldErrors>({
		title: null,
		endsAt: null,
		locationName: null,
		locationUrl: null,
		capacity: null,
		until: null
	});

	async function submit(params: EventParams): Promise<void> {
		if (!instance) return;
		submitting = true;
		bannerKind = null;
		fieldErrors = {
			title: null,
			endsAt: null,
			locationName: null,
			locationUrl: null,
			capacity: null,
			until: null
		};
		try {
			const created = await createEvent(instance, communitySlug, groupSlug, params);
			await goto(resolve(`/i/${page.params.instance}/c/${communitySlug}/e/${created.id}`));
		} catch (cause) {
			// Route each 422 field onto its input; an unmapped field or a
			// non-validation failure falls to the shared banner.
			const keys = eventParamsErrorKeys(cause);
			fieldErrors = {
				title: keys.titleKey ? t(keys.titleKey) : null,
				endsAt: keys.endsAtKey ? t(keys.endsAtKey) : null,
				locationName: keys.locationNameKey ? t(keys.locationNameKey) : null,
				locationUrl: keys.locationUrlKey ? t(keys.locationUrlKey) : null,
				capacity: keys.capacityKey ? t(keys.capacityKey) : null,
				until: keys.untilKey ? t(keys.untilKey) : null
			};
			bannerKind = keys.bannerKind;
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

	{#if bannerKind}
		<ErrorBanner kind={bannerKind} class="mb-4" />
	{/if}

	<EventForm mode="create" {submitting} errors={fieldErrors} onSubmit={submit} onCancel={cancel} />
{/if}
