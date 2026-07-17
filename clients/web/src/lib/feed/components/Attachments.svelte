<script lang="ts">
	import { fetchAuthedObjectUrl } from '$lib/feed/api.js';
	import type { Attachment } from '$lib/feed/types.js';
	import type { Instance } from '$lib/instances/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import AuthedImage from '$lib/ui/AuthedImage.svelte';

	interface Props {
		instance: Instance;
		attachments: Attachment[];
	}

	let { instance, attachments }: Props = $props();

	const images = $derived(attachments.filter((a) => a.kind === 'image'));
	const files = $derived(attachments.filter((a) => a.kind !== 'image'));

	let lightbox = $state<Attachment | null>(null);

	function formatSize(bytes: number): string {
		if (bytes < 1024) return `${bytes} B`;
		if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
		return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
	}

	// Downloads are Bearer-authorized too, so fetch the bytes then hand a
	// throwaway object URL to a programmatic <a download>.
	async function download(attachment: Attachment): Promise<void> {
		try {
			const url = await fetchAuthedObjectUrl(instance, attachment.download_url);
			const anchor = document.createElement('a');
			anchor.href = url;
			anchor.download = attachment.filename;
			document.body.appendChild(anchor);
			anchor.click();
			anchor.remove();
			URL.revokeObjectURL(url);
		} catch {
			/* a failed download is silent here — VersionSheet's stance */
		}
	}
</script>

{#if images.length > 0}
	<div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
		{#each images as image (image.id)}
			<button
				type="button"
				onclick={() => (lightbox = image)}
				class="group relative aspect-square overflow-hidden rounded-lg border border-line"
				aria-label={t('feed.attachment.view', { name: image.filename })}
			>
				<AuthedImage
					{instance}
					path={image.thumbnail_url ?? image.url}
					alt={image.filename}
					class="size-full object-cover transition-transform duration-200 group-hover:scale-105"
				/>
			</button>
		{/each}
	</div>
{/if}

{#if files.length > 0}
	<ul class="flex flex-col gap-1.5">
		{#each files as file (file.id)}
			<li>
				<button
					type="button"
					onclick={() => download(file)}
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
				</button>
			</li>
		{/each}
	</ul>
{/if}

{#if lightbox}
	<!-- Lightbox: a plain modal overlay, dismissed by click or Escape. -->
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-ink/80 p-4"
		role="button"
		tabindex="-1"
		aria-label={t('common.close')}
		onclick={() => (lightbox = null)}
		onkeydown={(event) => {
			if (event.key === 'Escape' || event.key === 'Enter') lightbox = null;
		}}
	>
		<AuthedImage
			{instance}
			path={lightbox.url}
			alt={lightbox.filename}
			class="max-h-full max-w-full rounded-lg object-contain"
		/>
	</div>
{/if}
