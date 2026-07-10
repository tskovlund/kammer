<script lang="ts">
	import { page } from '$app/state';
	import { confirmGuestComment } from '$lib/guest/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import ConfirmToken from '$lib/ui/ConfirmToken.svelte';
</script>

<svelte:head><title>{t('guest.comment.confirm.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	<ConfirmToken
		token={page.params.token}
		confirm={confirmGuestComment}
		loadingLabel={t('guest.comment.confirm.title')}
		errorTitle={t('guest.comment.confirm.error.title')}
		errorBody={t('guest.comment.confirm.error.body')}
	>
		{#snippet success({ guest_name })}
			<EmptyState
				title={t('guest.comment.confirm.success.title')}
				body={guest_name
					? t('guest.comment.confirm.success.bodyNamed', { name: guest_name })
					: t('guest.comment.confirm.success.body')}
			/>
		{/snippet}
	</ConfirmToken>
</PublicShell>
