<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';
</script>

<svelte:head><title>{t('nav.notifications')} · {t('app.name')}</title></svelte:head>

<h1 class="text-xl font-semibold tracking-tight text-ink">{t('nav.notifications')}</h1>

<EmptyState title={t('notifications.empty.title')} body={t('notifications.empty.body')}>
	{#snippet icon()}<TabIcon name="notifications" class="size-8" />{/snippet}
</EmptyState>
