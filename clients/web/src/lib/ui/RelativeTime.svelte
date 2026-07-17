<script lang="ts">
	import { formatDateTime, formatRelativeTime } from '$lib/i18n/datetime.js';
	import { i18n } from '$lib/i18n/i18n.svelte.js';
	import { minuteNow } from './now.js';

	interface Props {
		datetime: string;
		/** Extra classes for the rendered `<time>` element. */
		class?: string;
	}

	let { datetime, class: className = '' }: Props = $props();

	// `minuteNow()` keeps this fresh: without the reactive clock the string
	// renders once and fossilizes on a long-lived screen (part of #270).
	const relative = $derived(formatRelativeTime(datetime, i18n.locale, minuteNow()));
	const absolute = $derived(formatDateTime(datetime, i18n.locale));
</script>

<time {datetime} title={absolute} class="text-ink-faint {className}">{relative}</time>
