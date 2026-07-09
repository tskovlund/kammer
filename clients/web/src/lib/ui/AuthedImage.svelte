<script lang="ts">
	import { fetchAuthedObjectUrl } from '$lib/feed/api.js';
	import type { Instance } from '$lib/instances/types.js';

	interface Props {
		instance: Instance;
		/** Serializer-relative file path, e.g. `/api/v1/files/<id>/thumbnail`. */
		path: string;
		alt: string;
		class?: string;
	}

	let { instance, path, alt, class: className = '' }: Props = $props();

	let objectUrl = $state<string | null>(null);
	let failed = $state(false);

	// Post attachments sit behind the API's Bearer auth, so a plain <img src>
	// can't carry the device token. Fetch the bytes with the token, hand the
	// element an object URL, and revoke it when the path changes or unmounts.
	$effect(() => {
		let active = true;
		let created: string | null = null;
		failed = false;
		objectUrl = null;

		fetchAuthedObjectUrl(instance, path)
			.then((url) => {
				if (!active) {
					URL.revokeObjectURL(url);
					return;
				}
				created = url;
				objectUrl = url;
			})
			.catch(() => {
				if (active) failed = true;
			});

		return () => {
			active = false;
			if (created) URL.revokeObjectURL(created);
		};
	});
</script>

{#if objectUrl}
	<img src={objectUrl} {alt} class={className} loading="lazy" />
{:else if failed}
	<div
		class="flex items-center justify-center bg-paper text-xs text-ink-faint {className}"
		role="img"
		aria-label={alt}
	>
		⚠
	</div>
{:else}
	<div class="animate-[kammer-skeleton_2s_ease-in-out_infinite] bg-ink/10 {className}"></div>
{/if}
