<script lang="ts">
	import { fetchAuthedObjectUrl } from '$lib/feed/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import { dismissable } from '$lib/ui/dismissable.js';
	import type { FilesStore } from '../files-store.svelte.js';
	import { formatBytes } from '../logic.js';

	interface Props {
		store: FilesStore;
		instance: Instance;
	}

	let { store, instance }: Props = $props();

	let fileInput = $state<HTMLInputElement>();

	const detail = $derived(store.detail);

	async function download(path: string, filename: string): Promise<void> {
		try {
			const objectUrl = await fetchAuthedObjectUrl(instance, path);
			const anchor = document.createElement('a');
			anchor.href = objectUrl;
			anchor.download = filename;
			anchor.rel = 'noopener';
			document.body.appendChild(anchor);
			anchor.click();
			anchor.remove();
			URL.revokeObjectURL(objectUrl);
		} catch {
			/* the store surfaces load errors; a failed download is silent here */
		}
	}

	async function onPick(event: Event): Promise<void> {
		const input = event.currentTarget as HTMLInputElement;
		const file = input.files?.[0];
		input.value = '';
		if (file) await store.uploadVersion(file);
	}
</script>

{#if detail}
	<div
		class="fixed inset-0 z-40 flex items-end justify-center bg-ink/40 p-0 sm:items-center sm:p-4"
		role="presentation"
		onclick={(event) => {
			if (event.target === event.currentTarget) store.closeVersions();
		}}
	>
		<div
			class="flex max-h-[85vh] w-full max-w-lg flex-col overflow-hidden rounded-t-2xl border border-line bg-surface sm:rounded-2xl"
			role="dialog"
			aria-modal="true"
			aria-label={t('files.versions.title', { name: detail.filename })}
			use:dismissable={{ onDismiss: () => store.closeVersions() }}
		>
			<header class="flex items-center justify-between gap-3 border-b border-line px-5 py-4">
				<div class="min-w-0">
					<h2 class="truncate text-base font-semibold text-ink">{detail.filename}</h2>
					<p class="text-xs text-ink-muted">
						{t('files.versions.count', { count: String(detail.versions.length) })}
					</p>
				</div>
				<button
					type="button"
					class="shrink-0 rounded-lg p-1.5 text-ink-muted hover:bg-ink/5 hover:text-ink"
					aria-label={t('common.close')}
					onclick={() => store.closeVersions()}
				>
					<svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.5"
						class="size-5"
					>
						<path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
					</svg>
				</button>
			</header>

			<ul class="flex-1 divide-y divide-line overflow-y-auto">
				{#each detail.versions as version (version.id)}
					<li class="flex items-center gap-3 px-5 py-3">
						<div class="min-w-0 flex-1">
							<div class="flex items-center gap-2">
								<span class="truncate text-sm font-medium text-ink">
									{t('files.versions.number', { seq: String(version.version_seq) })}
								</span>
								{#if version.current}
									<span
										class="rounded-full border border-accent/25 bg-accent/5 px-2 py-0.5 text-[10px] font-medium text-accent"
									>
										{t('files.versions.current')}
									</span>
								{/if}
							</div>
							<p class="mt-0.5 text-xs text-ink-muted">
								{formatBytes(version.byte_size)}
								{#if version.uploaded_by}
									· {version.uploaded_by.display_name}
								{/if}
								· <RelativeTime datetime={version.uploaded_at} />
							</p>
						</div>
						<div class="flex shrink-0 items-center gap-1">
							<Button
								variant="ghost"
								size="sm"
								onclick={() => download(version.download_url, detail.filename)}
							>
								{t('files.download')}
							</Button>
							{#if (version.mine || store.canManage) && detail.versions.length > 1}
								<button
									type="button"
									class="rounded-lg p-1.5 text-ink-muted hover:bg-danger/5 hover:text-danger"
									aria-label={t('files.versions.delete')}
									onclick={() => store.removeVersion(version.id)}
								>
									<svg
										viewBox="0 0 24 24"
										fill="none"
										stroke="currentColor"
										stroke-width="1.5"
										class="size-4"
									>
										<path
											stroke-linecap="round"
											stroke-linejoin="round"
											d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"
										/>
									</svg>
								</button>
							{/if}
						</div>
					</li>
				{/each}
			</ul>

			{#if store.canWrite}
				<footer class="border-t border-line px-5 py-4">
					<input
						bind:this={fileInput}
						type="file"
						class="sr-only"
						aria-hidden="true"
						tabindex="-1"
						onchange={onPick}
					/>
					<Button
						variant="secondary"
						class="w-full"
						disabled={store.busy}
						onclick={() => fileInput?.click()}
					>
						{store.busy ? t('files.uploading') : t('files.versions.upload')}
					</Button>
				</footer>
			{/if}
		</div>
	</div>
{/if}
