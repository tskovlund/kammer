<script lang="ts">
	import type { ApiErrorKind } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';

	interface Props {
		/**
		 * Which failure occurred. The kind maps to shared, localized
		 * `errors.<kind>` copy — the server's English `ApiError.message` is
		 * never rendered here (#253/#270), so Danish users see Danish and no
		 * server internals leak.
		 */
		kind: ApiErrorKind;
		/** When provided, renders a dismiss "✕" that calls this. */
		ondismiss?: () => void;
		class?: string;
	}

	let { kind, ondismiss, class: className = '' }: Props = $props();
</script>

<div
	class="flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger {className}"
>
	<!-- Only the message is the live region: keeping the dismiss button out
	     of it means a screen reader announces the error, not "…, Dismiss". -->
	<span role="alert">{t(`errors.${kind}`)}</span>
	{#if ondismiss}
		<button
			type="button"
			class="shrink-0 text-danger/70 hover:text-danger"
			aria-label={t('common.dismiss')}
			onclick={ondismiss}
		>
			✕
		</button>
	{/if}
</div>
