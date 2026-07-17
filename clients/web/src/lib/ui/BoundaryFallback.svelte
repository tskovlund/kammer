<script lang="ts">
	import { afterNavigate } from '$app/navigation';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';

	interface Props {
		/** The `reset` handed to a `<svelte:boundary>`'s failed snippet. */
		reset: () => void;
	}

	let { reset }: Props = $props();

	// A tripped boundary destroys its children until reset() is called — so
	// while this card is mounted, navigating would otherwise change the URL
	// and tab highlight but keep showing the crash card on every route.
	// Resetting on navigation makes the nav a real way out: the boundary
	// re-renders whatever route the user just chose.
	afterNavigate(() => reset());
</script>

<div class="rounded-xl border border-line bg-surface">
	<EmptyState title={t('boundary.title')} body={t('boundary.body')}>
		<Button onclick={reset}>{t('common.retry')}</Button>
	</EmptyState>
</div>
