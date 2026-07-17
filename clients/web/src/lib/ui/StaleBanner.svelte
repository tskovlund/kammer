<script lang="ts">
	import { formatRelativeTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { online } from '$lib/offline/online.svelte.js';
	import { minuteNow } from '$lib/ui/now.js';

	interface Props {
		/** When the currently shown data was actually fetched (a snapshot-cache save time). */
		savedAt: string;
		class?: string;
	}

	let { savedAt, class: className = '' }: Props = $props();

	// minuteNow() keeps the shown age ticking — an offline banner is exactly
	// the screen that stays open for hours (part of #270).
	const relative = $derived(formatRelativeTime(savedAt, i18n.locale, minuteNow()));
</script>

<div
	class="mb-4 rounded-lg border border-line bg-paper px-3 py-2 text-sm text-ink-muted {className}"
	role="status"
>
	{online.value
		? t('offline.stale.unreachable', { time: relative })
		: t('offline.stale.offline', { time: relative })}
</div>
