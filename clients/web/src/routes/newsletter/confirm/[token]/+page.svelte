<script lang="ts">
	import { page } from '$app/state';
	import { confirmNewsletterSubscription } from '$lib/newsletter/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import ConfirmToken from '$lib/ui/ConfirmToken.svelte';
</script>

<svelte:head><title>{t('newsletter.confirm.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	<ConfirmToken
		token={page.params.token}
		confirm={confirmNewsletterSubscription}
		loadingLabel={t('newsletter.confirm.title')}
		errorTitle={t('newsletter.confirm.error.title')}
		errorBody={t('newsletter.confirm.error.body')}
	>
		{#snippet success({ guest_name })}
			<EmptyState
				title={t('newsletter.confirm.success.title')}
				body={guest_name
					? t('newsletter.confirm.success.bodyNamed', { name: guest_name })
					: t('newsletter.confirm.success.body')}
			/>
		{/snippet}
	</ConfirmToken>
</PublicShell>
