<script lang="ts">
	import { formatDateTime, formatRelativeTime } from '$lib/i18n/datetime.js';
	import { i18n } from '$lib/i18n/i18n.svelte.js';

	interface Props {
		datetime: string;
		/** Optional prefix note shown before the time, e.g. an "edited" marker. */
		class?: string;
	}

	let { datetime, class: className = '' }: Props = $props();

	const relative = $derived(formatRelativeTime(datetime, i18n.locale));
	const absolute = $derived(formatDateTime(datetime, i18n.locale));
</script>

<time {datetime} title={absolute} class="text-ink-faint {className}">{relative}</time>
