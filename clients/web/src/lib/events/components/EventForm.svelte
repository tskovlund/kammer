<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import type { Event, EventFieldErrors, EventParams } from '../types.js';

	interface Props {
		mode: 'create' | 'edit';
		initial?: Event | null;
		submitting: boolean;
		/** Per-field 422 copy from the page's `eventParamsErrorKeys` mapping. */
		errors?: EventFieldErrors;
		onSubmit: (params: EventParams) => void;
		onCancel: () => void;
	}

	const noErrors: EventFieldErrors = {
		title: null,
		endsAt: null,
		locationName: null,
		locationUrl: null,
		until: null
	};

	let { mode, initial = null, submitting, errors = noErrors, onSubmit, onCancel }: Props = $props();

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
	// Held as `string` (narrowed back to the union in `submit`) so it can bind
	// to the shared `Select`, whose `value` writes back a plain string.
	let frequency = $state<string>('weekly');
	let until = $state('');

	const frequencyOptions = $derived([
		{ value: 'weekly', label: t('events.form.weekly') },
		{ value: 'biweekly', label: t('events.form.biweekly') },
		{ value: 'monthly', label: t('events.form.monthly') }
	]);

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
			params.recurrence = { frequency: frequency as 'weekly' | 'biweekly' | 'monthly', until };
		}

		onSubmit(params);
	}

	const fieldClass =
		'w-full rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink placeholder:text-ink-faint focus-visible:border-accent';
</script>

<form onsubmit={submit} class="flex flex-col gap-4" id="event-form">
	<Input
		id="event-form-title"
		label={t('events.form.title')}
		bind:value={title}
		error={errors.title}
		required
	/>

	<label class="flex flex-col gap-1">
		<span class="text-sm font-medium text-ink">{t('events.form.description')}</span>
		<textarea bind:value={description} rows="4" maxlength={50000} class="{fieldClass} resize-y"
		></textarea>
		<span class="text-xs text-ink-faint">{t('feed.compose.markdownHint')}</span>
	</label>

	<div class="flex flex-col gap-4 sm:flex-row">
		<Input
			id="event-form-starts-at"
			class="flex-1"
			type="datetime-local"
			label={t('events.form.startsAt')}
			bind:value={startsAt}
			required
		/>
		<Input
			id="event-form-ends-at"
			class="flex-1"
			type="datetime-local"
			label={t('events.form.endsAt')}
			bind:value={endsAt}
			error={errors.endsAt}
		/>
	</div>

	<label class="flex items-center gap-2">
		<input type="checkbox" bind:checked={allDay} class="size-4 rounded border-line" />
		<span class="text-sm text-ink">{t('events.form.allDay')}</span>
	</label>

	<div class="flex flex-col gap-4 sm:flex-row">
		<Input
			id="event-form-location-name"
			class="flex-1"
			label={t('events.form.locationName')}
			bind:value={locationName}
			error={errors.locationName}
		/>
		<Input
			id="event-form-location-url"
			class="flex-1"
			label={t('events.form.locationUrl')}
			bind:value={locationUrl}
			error={errors.locationUrl}
			inputmode="url"
		/>
	</div>

	{#if mode === 'create'}
		<div class="flex flex-col gap-3 rounded-lg border border-line p-3">
			<label class="flex items-center gap-2">
				<input type="checkbox" bind:checked={repeats} class="size-4 rounded border-line" />
				<span class="text-sm font-medium text-ink">{t('events.form.repeats')}</span>
			</label>
			{#if repeats}
				<div class="flex flex-col gap-4 sm:flex-row">
					<Select
						id="event-form-frequency"
						class="flex-1"
						label={t('events.form.frequency')}
						options={frequencyOptions}
						bind:value={frequency}
					/>
					<Input
						id="event-form-until"
						class="flex-1"
						type="date"
						label={t('events.form.until')}
						bind:value={until}
						error={errors.until}
						required={repeats}
					/>
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
