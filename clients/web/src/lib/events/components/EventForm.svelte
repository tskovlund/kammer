<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import type { Event, EventParams } from '../types.js';

	interface Props {
		mode: 'create' | 'edit';
		initial?: Event | null;
		submitting: boolean;
		onSubmit: (params: EventParams) => void;
		onCancel: () => void;
	}

	let { mode, initial = null, submitting, onSubmit, onCancel }: Props = $props();

	// datetime-local wants `YYYY-MM-DDTHH:mm` in local time; the API wants an
	// absolute ISO instant. We convert on the way in and out.
	function toLocalInput(iso: string | null | undefined): string {
		if (!iso) return '';
		const date = new Date(iso);
		const pad = (n: number) => String(n).padStart(2, '0');
		return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
	}

	const browserTz = Intl.DateTimeFormat().resolvedOptions().timeZone;

	// svelte-ignore state_referenced_locally
	let title = $state(initial?.title ?? '');
	// svelte-ignore state_referenced_locally
	let description = $state(initial?.description_markdown ?? '');
	// svelte-ignore state_referenced_locally
	let startsAt = $state(toLocalInput(initial?.starts_at));
	// svelte-ignore state_referenced_locally
	let endsAt = $state(toLocalInput(initial?.ends_at));
	// svelte-ignore state_referenced_locally
	let allDay = $state(initial?.all_day ?? false);
	// svelte-ignore state_referenced_locally
	let locationName = $state(initial?.location_name ?? '');
	// svelte-ignore state_referenced_locally
	let locationUrl = $state(initial?.location_url ?? '');

	// Recurrence is create-only (ADR 0019: editing is per-occurrence).
	let repeats = $state(false);
	let frequency = $state<'weekly' | 'biweekly' | 'monthly'>('weekly');
	let until = $state('');

	const canSubmit = $derived(title.trim().length > 0 && startsAt.length > 0 && !submitting);

	function submit(submitEvent: SubmitEvent): void {
		submitEvent.preventDefault();
		if (!canSubmit) return;

		const params: EventParams = {
			title: title.trim(),
			description_markdown: description.trim() || null,
			starts_at: new Date(startsAt).toISOString(),
			ends_at: endsAt ? new Date(endsAt).toISOString() : null,
			all_day: allDay,
			timezone: browserTz,
			location_name: locationName.trim() || null,
			location_url: locationUrl.trim() || null
		};

		if (mode === 'create' && repeats && until) {
			params.recurrence = { frequency, until };
		}

		onSubmit(params);
	}

	const fieldClass =
		'w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink placeholder:text-ink-faint focus-visible:border-accent';
</script>

<form onsubmit={submit} class="flex flex-col gap-4" id="event-form">
	<label class="flex flex-col gap-1">
		<span class="text-sm font-medium text-ink">{t('events.form.title')}</span>
		<input bind:value={title} required class={fieldClass} />
	</label>

	<label class="flex flex-col gap-1">
		<span class="text-sm font-medium text-ink">{t('events.form.description')}</span>
		<textarea bind:value={description} rows="4" class="{fieldClass} resize-y"></textarea>
		<span class="text-xs text-ink-faint">{t('feed.compose.markdownHint')}</span>
	</label>

	<div class="flex flex-col gap-4 sm:flex-row">
		<label class="flex flex-1 flex-col gap-1">
			<span class="text-sm font-medium text-ink">{t('events.form.startsAt')}</span>
			<input type="datetime-local" bind:value={startsAt} required class={fieldClass} />
		</label>
		<label class="flex flex-1 flex-col gap-1">
			<span class="text-sm font-medium text-ink">{t('events.form.endsAt')}</span>
			<input type="datetime-local" bind:value={endsAt} class={fieldClass} />
		</label>
	</div>

	<label class="flex items-center gap-2">
		<input type="checkbox" bind:checked={allDay} class="size-4 rounded border-line" />
		<span class="text-sm text-ink">{t('events.form.allDay')}</span>
	</label>

	<div class="flex flex-col gap-4 sm:flex-row">
		<label class="flex flex-1 flex-col gap-1">
			<span class="text-sm font-medium text-ink">{t('events.form.locationName')}</span>
			<input bind:value={locationName} class={fieldClass} />
		</label>
		<label class="flex flex-1 flex-col gap-1">
			<span class="text-sm font-medium text-ink">{t('events.form.locationUrl')}</span>
			<input bind:value={locationUrl} inputmode="url" class={fieldClass} />
		</label>
	</div>

	{#if mode === 'create'}
		<div class="flex flex-col gap-3 rounded-lg border border-line p-3">
			<label class="flex items-center gap-2">
				<input type="checkbox" bind:checked={repeats} class="size-4 rounded border-line" />
				<span class="text-sm font-medium text-ink">{t('events.form.repeats')}</span>
			</label>
			{#if repeats}
				<div class="flex flex-col gap-4 sm:flex-row">
					<label class="flex flex-1 flex-col gap-1">
						<span class="text-sm font-medium text-ink">{t('events.form.frequency')}</span>
						<select bind:value={frequency} class={fieldClass}>
							<option value="weekly">{t('events.form.weekly')}</option>
							<option value="biweekly">{t('events.form.biweekly')}</option>
							<option value="monthly">{t('events.form.monthly')}</option>
						</select>
					</label>
					<label class="flex flex-1 flex-col gap-1">
						<span class="text-sm font-medium text-ink">{t('events.form.until')}</span>
						<input type="date" bind:value={until} required={repeats} class={fieldClass} />
					</label>
				</div>
			{/if}
		</div>
	{/if}

	<div class="flex items-center justify-end gap-2">
		<Button variant="ghost" size="sm" onclick={onCancel}>{t('common.cancel')}</Button>
		<Button type="submit" variant="primary" size="sm" disabled={!canSubmit}>
			{#if submitting}
				{t('common.sending')}
			{:else if mode === 'create'}
				{t('events.form.create')}
			{:else}
				{t('common.save')}
			{/if}
		</Button>
	</div>
</form>
