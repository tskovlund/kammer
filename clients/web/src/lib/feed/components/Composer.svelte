<script lang="ts">
	import { tick } from 'svelte';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { FeedApiError, uploadFile } from '$lib/feed/api.js';
	import type { FeedStore } from '$lib/feed/feed-store.svelte.js';
	import type { StoredFile } from '$lib/feed/types.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';

	interface Props {
		store: FeedStore;
		instance: Instance;
		ref: { community: string; group: string };
	}

	let { store, instance, ref }: Props = $props();

	let body = $state('');
	let previewing = $state(false);
	let ackRequired = $state(false);
	let expanded = $state(false);
	let submitting = $state(false);

	let textarea = $state<HTMLTextAreaElement>();
	// Set while we programmatically return focus to the textarea after a reset,
	// so its focus handler doesn't immediately re-expand the collapsed composer.
	let restoringFocus = false;

	// Poll builder (null until the author adds a poll).
	interface PollDraft {
		options: { text: string }[];
		multipleChoice: boolean;
		anonymous: boolean;
		closesAt: string;
	}
	let poll = $state<PollDraft | null>(null);

	// Attachments already uploaded (ids go into stored_file_ids on publish).
	let uploads = $state<StoredFile[]>([]);
	let uploading = $state(false);
	let uploadError = $state<string | null>(null);

	const pollOptions = $derived(
		poll?.options.filter((option) => option.text.trim().length > 0) ?? []
	);
	const canSubmit = $derived(
		!submitting &&
			!uploading &&
			(body.trim().length > 0 || uploads.length > 0 || (poll !== null && pollOptions.length >= 2))
	);

	function addPoll(): void {
		poll = {
			options: [{ text: '' }, { text: '' }],
			multipleChoice: false,
			anonymous: false,
			closesAt: ''
		};
	}

	function addOption(): void {
		if (poll) poll = { ...poll, options: [...poll.options, { text: '' }] };
	}

	function removeOption(index: number): void {
		if (poll && poll.options.length > 2) {
			poll = { ...poll, options: poll.options.filter((_, i) => i !== index) };
		}
	}

	async function onFiles(event: Event): Promise<void> {
		const input = event.target as HTMLInputElement;
		const files = Array.from(input.files ?? []);
		input.value = '';
		if (files.length === 0) return;

		uploading = true;
		uploadError = null;
		for (const file of files) {
			try {
				uploads = [...uploads, await uploadFile(instance, ref, file)];
			} catch (error) {
				uploadError =
					error instanceof FeedApiError
						? error.kind === 'too_large'
							? t('feed.compose.uploadTooLarge', { name: file.name })
							: error.message
						: t('feed.compose.uploadFailed', { name: file.name });
			}
		}
		uploading = false;
	}

	function removeUpload(id: string): void {
		uploads = uploads.filter((upload) => upload.id !== id);
	}

	async function reset(): Promise<void> {
		body = '';
		previewing = false;
		ackRequired = false;
		poll = null;
		uploads = [];
		uploadError = null;
		expanded = false;
		// Collapsing unmounts the submit/cancel buttons, so focus would strand on
		// a removed node and fall to <body>. Return it to the composer's text
		// field (rendered once previewing is off) instead. `restoringFocus` keeps
		// the field's focus handler from re-expanding what we just collapsed.
		await tick();
		restoringFocus = true;
		textarea?.focus();
		restoringFocus = false;
	}

	async function publish(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (!canSubmit) return;
		submitting = true;
		store.clearActionError();

		const ok = await store.publish({
			body_markdown: body.trim() || undefined,
			acknowledgment_required: ackRequired || undefined,
			stored_file_ids: uploads.length > 0 ? uploads.map((upload) => upload.id) : undefined,
			poll:
				poll && pollOptions.length >= 2
					? {
							options: pollOptions.map((option) => ({ text: option.text.trim() })),
							multiple_choice: poll.multipleChoice,
							anonymous: poll.anonymous,
							closes_at: poll.closesAt ? new Date(poll.closesAt).toISOString() : null
						}
					: undefined
		});

		submitting = false;
		if (ok) reset();
	}
</script>

<form
	id="post-composer"
	onsubmit={publish}
	class="flex flex-col gap-3 rounded-xl border border-line bg-surface p-4"
>
	<div class="flex flex-col gap-1.5">
		{#if previewing}
			<div
				class="min-h-24 rounded-lg border border-line bg-paper/40 px-3 py-2 text-[0.95rem] text-ink"
			>
				{#if body.trim()}
					<Markdown source={body} />
				{:else}
					<p class="text-sm text-ink-faint">{t('feed.compose.previewEmpty')}</p>
				{/if}
			</div>
		{:else}
			<textarea
				bind:this={textarea}
				bind:value={body}
				onfocus={() => {
					if (!restoringFocus) expanded = true;
				}}
				rows={expanded ? 4 : 2}
				placeholder={t('feed.compose.placeholder')}
				aria-label={t('feed.compose.placeholder')}
				class="w-full resize-y rounded-lg border border-line bg-surface px-3 py-2 text-[0.95rem] text-ink transition-colors duration-150 placeholder:text-ink-faint hover:border-ink-faint/60 focus-visible:border-accent"
			></textarea>
		{/if}
		<div class="flex items-center justify-between">
			<p class="text-xs text-ink-faint">{t('feed.compose.markdownHint')}</p>
			{#if body.trim()}
				<button
					type="button"
					class="text-xs text-accent hover:underline"
					onclick={() => (previewing = !previewing)}
				>
					{previewing ? t('feed.compose.write') : t('feed.compose.preview')}
				</button>
			{/if}
		</div>
	</div>

	{#if expanded}
		{#if uploads.length > 0}
			<ul class="flex flex-wrap gap-2">
				{#each uploads as upload (upload.id)}
					<li
						class="flex items-center gap-2 rounded-lg border border-line bg-paper/40 px-2.5 py-1.5 text-xs"
					>
						<span class="max-w-40 truncate text-ink">{upload.filename}</span>
						<button
							type="button"
							class="text-ink-faint hover:text-danger"
							aria-label={t('feed.compose.removeAttachment', { name: upload.filename })}
							onclick={() => removeUpload(upload.id)}
						>
							✕
						</button>
					</li>
				{/each}
			</ul>
		{/if}
		{#if uploadError}
			<p class="text-sm text-danger" role="alert">{uploadError}</p>
		{/if}

		{#if poll}
			<fieldset class="flex flex-col gap-2 rounded-lg border border-line p-3">
				<legend class="px-1 text-xs font-medium text-ink-muted">{t('feed.compose.poll')}</legend>
				{#each poll.options as option, index (index)}
					<div class="flex items-center gap-2">
						<input
							bind:value={option.text}
							placeholder={t('feed.compose.pollOption', { n: String(index + 1) })}
							aria-label={t('feed.compose.pollOption', { n: String(index + 1) })}
							class="h-9 flex-1 rounded-lg border border-line bg-surface px-2.5 text-sm text-ink hover:border-ink-faint/60 focus-visible:border-accent"
						/>
						{#if poll.options.length > 2}
							<button
								type="button"
								class="text-ink-faint hover:text-danger"
								aria-label={t('feed.compose.removeOption')}
								onclick={() => removeOption(index)}
							>
								✕
							</button>
						{/if}
					</div>
				{/each}
				<button
					type="button"
					class="self-start text-xs text-accent hover:underline"
					onclick={addOption}
				>
					{t('feed.compose.addOption')}
				</button>
				<div class="flex flex-wrap gap-x-4 gap-y-2 text-sm text-ink-muted">
					<label class="flex items-center gap-2">
						<input type="checkbox" bind:checked={poll.multipleChoice} class="accent-accent" />
						{t('feed.compose.multipleChoice')}
					</label>
					<label class="flex items-center gap-2">
						<input type="checkbox" bind:checked={poll.anonymous} class="accent-accent" />
						{t('feed.compose.anonymous')}
					</label>
					<label class="flex items-center gap-2">
						{t('feed.compose.closesAt')}
						<input
							type="datetime-local"
							bind:value={poll.closesAt}
							class="rounded-lg border border-line bg-surface px-2 py-1 text-sm text-ink"
						/>
					</label>
				</div>
			</fieldset>
		{/if}

		<label class="flex items-center gap-2 text-sm text-ink-muted">
			<input type="checkbox" bind:checked={ackRequired} class="accent-accent" />
			{t('feed.compose.ackRequired')}
		</label>

		<div class="flex flex-wrap items-center justify-between gap-2">
			<div class="flex items-center gap-1">
				<label
					class="flex cursor-pointer items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-ink-muted hover:bg-ink/5"
				>
					<svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.5"
						class="size-4"
						aria-hidden="true"
					>
						<path
							stroke-linecap="round"
							stroke-linejoin="round"
							d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909M18 9.75h.008M21 12V6.75A2.25 2.25 0 0018.75 4.5H5.25A2.25 2.25 0 003 6.75v10.5A2.25 2.25 0 005.25 19.5h9.75"
						/>
					</svg>
					{t('feed.compose.attach')}
					<input type="file" multiple class="hidden" onchange={onFiles} disabled={uploading} />
				</label>
				{#if !poll}
					<button
						type="button"
						onclick={addPoll}
						class="flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm text-ink-muted hover:bg-ink/5"
					>
						<svg
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="1.5"
							class="size-4"
							aria-hidden="true"
						>
							<path
								stroke-linecap="round"
								stroke-linejoin="round"
								d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"
							/>
						</svg>
						{t('feed.compose.addPoll')}
					</button>
				{/if}
			</div>
			<div class="flex items-center gap-2">
				<Button variant="ghost" size="sm" onclick={reset}>{t('common.cancel')}</Button>
				<Button type="submit" variant="primary" size="sm" disabled={!canSubmit}>
					{submitting ? t('feed.compose.publishing') : t('feed.compose.publish')}
				</Button>
			</div>
		</div>
	{/if}
</form>
