<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Attachment } from '$lib/feed/types.js';

	/**
	 * Read-only attachment rendering for anonymous public visitors (issue
	 * #185 slice B). Unlike the authenticated feed's `Attachments.svelte`,
	 * this can't fetch bytes with a Bearer token — it links straight to the
	 * serializer's plain `url`/`download_url`. The public-file-serving path
	 * that makes those URLs actually resolve for an anonymous request is
	 * landing in a parallel PR, so today a guest visiting this page may see
	 * a 404 on an image; `onerror` catches that per-image and swaps in a
	 * neutral placeholder instead of a broken-image icon, rather than
	 * failing the whole page.
	 */
	interface Props {
		attachments: Attachment[];
	}

	let { attachments }: Props = $props();

	const images = $derived(attachments.filter((a) => a.kind === 'image'));
	const files = $derived(attachments.filter((a) => a.kind !== 'image'));

	let failed = $state<Record<string, boolean>>({});

	function formatSize(bytes: number): string {
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
		return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
	}
</script>

{#if images.length > 0}
	<div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
		{#each images as image (image.id)}
			{#if failed[image.id]}
				<div
					class="flex aspect-square items-center justify-center rounded-lg border border-line bg-paper text-center text-xs text-ink-faint"
					role="img"
					aria-label={image.filename}
				>
					{t('public.post.attachments.unavailable')}
				</div>
			{:else}
				<img
					src={image.thumbnail_url ?? image.url}
					alt={image.filename}
					loading="lazy"
					onerror={() => (failed = { ...failed, [image.id]: true })}
					class="aspect-square rounded-lg border border-line object-cover"
				/>
			{/if}
		{/each}
	</div>
{/if}

{#if files.length > 0}
	<ul class="flex flex-col gap-1.5">
		{#each files as file (file.id)}
			<li>
				<!-- Not a SvelteKit route — a same-origin static file download, so
				     it deliberately bypasses the client router (`resolve()` only
				     resolves app routes, not `/api/v1/files/...` asset paths). -->
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					href={file.download_url}
					class="flex w-full items-center gap-2.5 rounded-lg border border-line bg-surface px-3 py-2 text-left transition-colors duration-150 hover:border-ink-faint/60"
				>
					<svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.5"
						class="size-5 shrink-0 text-ink-faint"
						aria-hidden="true"
					>
						<path
							stroke-linecap="round"
							stroke-linejoin="round"
							d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75L12 18m0 0l3.75-2.25M12 18v-6"
						/>
					</svg>
					<span class="min-w-0 flex-1">
						<span class="block truncate text-sm text-ink">{file.filename}</span>
						<span class="block text-xs text-ink-faint">{formatSize(file.byte_size)}</span>
					</span>
					<span class="text-xs text-accent">{t('feed.attachment.download')}</span>
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			</li>
		{/each}
	</ul>
{/if}
