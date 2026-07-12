<script lang="ts">
	import { ApiError } from '$lib/api/errors.js';
	import {
		fetchCustomFields,
		createCustomField,
		updateCustomField,
		deleteCustomField,
		type CustomField,
		type CustomFieldParams
	} from '$lib/manage/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The community's roster columns (issue #259, ADR 0020): the manager
	// surface that the LiveView settings page owned — list, add, edit a
	// field's label / visibility / required flag, delete. A field's type
	// and options are fixed at creation (changing them would orphan
	// answers); everything else stays editable. The server holds the
	// `:manage_community` gate; this only renders on a page already gated
	// on it.
	let { instance, communitySlug }: { instance: Instance; communitySlug: string } = $props();

	let fields = $state<CustomField[]>([]);
	let loading = $state(true);
	let loadFailed = $state(false);
	// One mutation at a time. `busyId` is the field with an in-flight
	// request; `confirmingId`/`editingId` are the (local) delete-confirm
	// and edit modes; `actionError` surfaces a failed toggle/delete/save
	// on its row (the add form has its own error state below).
	let busyId = $state<string | null>(null);
	let confirmingId = $state<string | null>(null);
	let editingId = $state<string | null>(null);
	let actionError = $state<{ id: string; text: string } | null>(null);

	// Edit-form state (label + visibility of the field being edited).
	let editLabel = $state('');
	let editVisibility = $state<CustomField['visibility']>('members');
	let editLabelError = $state<string | null>(null);

	// Add-field form.
	let label = $state('');
	let fieldType = $state<CustomField['field_type']>('text');
	let optionsText = $state('');
	let visibility = $state<CustomField['visibility']>('members');
	let required = $state(false);
	let adding = $state(false);
	// Field-level 422 copy, keyed on the changeset field names — never the
	// server's English strings (#253).
	let labelError = $state<string | null>(null);
	let optionsError = $state<string | null>(null);
	let addFailed = $state(false);

	$effect(() => {
		const inst = instance;
		const slug = communitySlug;
		if (!inst || !slug) return;

		let cancelled = false;
		loading = true;
		loadFailed = false;

		(async () => {
			try {
				const loaded = await fetchCustomFields(inst, slug);
				if (!cancelled) fields = loaded;
			} catch {
				if (!cancelled) loadFailed = true;
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function add(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (adding || busyId) return;
		adding = true;
		labelError = null;
		optionsError = null;
		addFailed = false;

		const params: CustomFieldParams = {
			label,
			field_type: fieldType,
			visibility,
			required,
			options: fieldType === 'single_select' ? splitOptions(optionsText) : []
		};

		try {
			const created = await createCustomField(instance, communitySlug, params);
			fields = [...fields, created];
			label = '';
			optionsText = '';
			fieldType = 'text';
			visibility = 'members';
			required = false;
		} catch (cause) {
			if (cause instanceof ApiError && cause.kind === 'validation') {
				labelError = cause.details.label ? t('manage.fields.error.label') : null;
				optionsError = cause.details.options ? t('manage.fields.error.options') : null;
				if (!labelError && !optionsError) addFailed = true;
			} else {
				addFailed = true;
			}
		} finally {
			adding = false;
		}
	}

	async function toggleRequired(field: CustomField): Promise<void> {
		if (busyId) return;
		busyId = field.id;
		actionError = null;
		const target = !field.required;
		// Drive the checkbox through state, optimistically. A one-way
		// `checked={field.required}` does NOT revert a native click by itself
		// (Svelte's cached attribute already equals the unchanged value, so a
		// re-render short-circuits), which would leave the box lying about the
		// server after a failure — so flip the stored value now and undo it if
		// the request is refused.
		fields = setRequired(fields, field.id, target);
		try {
			const updated = await updateCustomField(instance, communitySlug, field.id, {
				required: target
			});
			fields = replaceField(fields, updated);
		} catch {
			fields = setRequired(fields, field.id, !target);
			actionError = { id: field.id, text: t('manage.fields.saveError') };
		} finally {
			busyId = null;
		}
	}

	function startEdit(field: CustomField): void {
		if (busyId) return;
		editingId = field.id;
		editLabel = field.label;
		editVisibility = field.visibility;
		editLabelError = null;
		actionError = null;
		confirmingId = null;
	}

	function cancelEdit(): void {
		editingId = null;
		editLabelError = null;
	}

	async function saveEdit(event: SubmitEvent, field: CustomField): Promise<void> {
		event.preventDefault();
		if (busyId) return;
		busyId = field.id;
		editLabelError = null;
		actionError = null;
		try {
			const updated = await updateCustomField(instance, communitySlug, field.id, {
				label: editLabel,
				visibility: editVisibility
			});
			fields = replaceField(fields, updated);
			editingId = null;
		} catch (cause) {
			if (cause instanceof ApiError && cause.kind === 'validation' && cause.details.label) {
				editLabelError = t('manage.fields.error.label');
			} else {
				actionError = { id: field.id, text: t('manage.fields.saveError') };
			}
		} finally {
			busyId = null;
		}
	}

	async function remove(field: CustomField): Promise<void> {
		if (busyId) return;
		busyId = field.id;
		actionError = null;
		try {
			await deleteCustomField(instance, communitySlug, field.id);
			fields = fields.filter((existing) => existing.id !== field.id);
		} catch {
			actionError = { id: field.id, text: t('manage.fields.deleteError') };
		} finally {
			busyId = null;
			confirmingId = null;
		}
	}

	function setRequired(list: CustomField[], id: string, value: boolean): CustomField[] {
		return list.map((existing) =>
			existing.id === id ? { ...existing, required: value } : existing
		);
	}

	function replaceField(list: CustomField[], updated: CustomField): CustomField[] {
		return list.map((existing) => (existing.id === updated.id ? updated : existing));
	}

	function splitOptions(text: string): string[] {
		return text
			.split('\n')
			.map((line) => line.trim())
			.filter((line) => line !== '');
	}

	function typeLabel(field: CustomField): string {
		return field.field_type === 'single_select'
			? t('manage.fields.type.singleSelect')
			: t('manage.fields.type.text');
	}

	function visibilityLabel(field: CustomField): string {
		return field.visibility === 'admins'
			? t('manage.fields.visibility.admins')
			: t('manage.fields.visibility.members');
	}
</script>

<section class="mt-10 max-w-lg" aria-labelledby="custom-fields-heading">
	<h2 id="custom-fields-heading" class="text-sm font-medium text-ink">
		{t('manage.fields.title')}
	</h2>
	<p class="mt-1 text-sm text-ink-muted">{t('manage.fields.description')}</p>

	{#if loading}
		<div class="mt-4 flex flex-col gap-2"><Skeleton class="h-12" /><Skeleton class="h-12" /></div>
	{:else}
		{#if loadFailed}
			<p class="mt-4 text-sm text-danger" role="alert">{t('manage.fields.loadError')}</p>
		{:else if fields.length === 0}
			<p class="mt-4 text-sm text-ink-faint">{t('manage.fields.empty')}</p>
		{:else}
			<ul id="custom-fields-list" class="mt-4 divide-y divide-line rounded-lg border border-line">
				{#each fields as field (field.id)}
					<li id="custom-field-{field.id}" class="p-3">
						{#if editingId === field.id}
							<form
								id="custom-field-edit-form-{field.id}"
								class="flex flex-col gap-3"
								onsubmit={(event) => saveEdit(event, field)}
							>
								<Input
									id="custom-field-edit-label-{field.id}"
									label={t('manage.fields.label')}
									bind:value={editLabel}
									error={editLabelError}
									required
								/>
								<Select
									id="custom-field-edit-visibility-{field.id}"
									label={t('manage.fields.visibility')}
									bind:value={editVisibility}
									options={[
										{ value: 'members', label: t('manage.fields.visibility.members') },
										{ value: 'admins', label: t('manage.fields.visibility.admins') }
									]}
								/>
								<div class="flex items-center gap-2">
									<Button
										type="submit"
										variant="secondary"
										size="sm"
										id="custom-field-save-{field.id}"
										disabled={busyId !== null}
									>
										{t('manage.fields.save')}
									</Button>
									<Button
										type="button"
										variant="ghost"
										size="sm"
										disabled={busyId !== null}
										onclick={cancelEdit}
									>
										{t('common.cancel')}
									</Button>
								</div>
							</form>
						{:else}
							<div class="flex items-start justify-between gap-3">
								<div class="min-w-0">
									<p class="truncate text-sm font-medium text-ink">{field.label}</p>
									<p class="text-xs text-ink-faint">
										{typeLabel(field)} · {visibilityLabel(field)}
									</p>
									<label class="mt-2 flex items-center gap-2 text-sm text-ink">
										<input
											id="custom-field-required-{field.id}"
											type="checkbox"
											checked={field.required}
											disabled={busyId !== null}
											onchange={() => toggleRequired(field)}
											class="size-4 rounded border-line text-accent focus:ring-accent"
										/>
										{t('manage.fields.required')}
									</label>
								</div>

								<div class="flex shrink-0 items-center gap-2">
									{#if confirmingId === field.id}
										<Button
											variant="danger"
											size="sm"
											id="custom-field-confirm-delete-{field.id}"
											disabled={busyId !== null}
											onclick={() => remove(field)}
										>
											{t('manage.fields.confirmDelete')}
										</Button>
										<Button
											variant="ghost"
											size="sm"
											disabled={busyId !== null}
											onclick={() => (confirmingId = null)}
										>
											{t('common.cancel')}
										</Button>
									{:else}
										<Button
											variant="ghost"
											size="sm"
											id="custom-field-edit-{field.id}"
											disabled={busyId !== null}
											onclick={() => startEdit(field)}
										>
											{t('manage.fields.edit')}
										</Button>
										<Button
											variant="ghost"
											size="sm"
											id="custom-field-delete-{field.id}"
											disabled={busyId !== null}
											onclick={() => (confirmingId = field.id)}
										>
											{t('manage.fields.delete')}
										</Button>
									{/if}
								</div>
							</div>
						{/if}

						{#if actionError?.id === field.id}
							<p class="mt-2 text-xs text-danger" role="alert">{actionError.text}</p>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		<form id="custom-fields-add-form" class="mt-6 flex flex-col gap-4" onsubmit={add}>
			<h3 class="text-sm font-medium text-ink">{t('manage.fields.addTitle')}</h3>
			<Input
				id="custom-field-label"
				label={t('manage.fields.label')}
				bind:value={label}
				error={labelError}
				required
			/>
			<Select
				id="custom-field-type"
				label={t('manage.fields.type')}
				bind:value={fieldType}
				options={[
					{ value: 'text', label: t('manage.fields.type.text') },
					{ value: 'single_select', label: t('manage.fields.type.singleSelect') }
				]}
			/>
			{#if fieldType === 'single_select'}
				<div class="flex flex-col gap-1.5">
					<label for="custom-field-options" class="text-sm font-medium text-ink">
						{t('manage.fields.options')}
					</label>
					<textarea
						id="custom-field-options"
						bind:value={optionsText}
						rows="3"
						class={[
							'rounded-lg border bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none',
							optionsError ? 'border-danger' : 'border-line'
						]}></textarea>
					{#if optionsError}
						<p class="text-xs text-danger" role="alert">{optionsError}</p>
					{:else}
						<p class="text-xs text-ink-faint">{t('manage.fields.optionsHint')}</p>
					{/if}
				</div>
			{/if}
			<Select
				id="custom-field-visibility"
				label={t('manage.fields.visibility')}
				bind:value={visibility}
				options={[
					{ value: 'members', label: t('manage.fields.visibility.members') },
					{ value: 'admins', label: t('manage.fields.visibility.admins') }
				]}
			/>
			<label class="flex items-center gap-2 text-sm text-ink">
				<input
					id="custom-field-required"
					type="checkbox"
					bind:checked={required}
					class="size-4 rounded border-line text-accent focus:ring-accent"
				/>
				{t('manage.fields.requiredNew')}
			</label>
			<div class="flex items-center gap-3">
				<Button type="submit" variant="secondary" disabled={adding || busyId !== null}>
					{adding ? t('common.sending') : t('manage.fields.add')}
				</Button>
				{#if addFailed}
					<span class="text-sm text-danger" role="alert">{t('manage.fields.addError')}</span>
				{/if}
			</div>
		</form>
	{/if}
</section>
