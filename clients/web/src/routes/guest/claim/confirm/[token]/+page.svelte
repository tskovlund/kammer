<script lang="ts">
	import { page } from '$app/state';
	import { confirmGuestClaim, GuestApiError } from '$lib/guest/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import ConfirmToken from '$lib/ui/ConfirmToken.svelte';
</script>

<svelte:head><title>{t('guest.claim.confirm.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	<ConfirmToken
		token={page.params.token}
		confirm={confirmGuestClaim}
		loadingLabel={t('guest.claim.confirm.title')}
		errorTitle={t('guest.claim.confirm.error.title')}
		errorBody={t('guest.claim.confirm.error.body')}
	>
		{#snippet success({ guest_name })}
			<EmptyState
				title={t('guest.claim.confirm.success.title')}
				body={guest_name
					? t('guest.claim.confirm.success.bodyNamed', { name: guest_name })
					: t('guest.claim.confirm.success.body')}
			/>
		{/snippet}
		{#snippet error(caught)}
			{#if caught instanceof GuestApiError && caught.status === 422}
				<EmptyState
					title={t('guest.claim.confirm.full.title')}
					body={t('guest.claim.confirm.full.body')}
				/>
			{:else}
				<EmptyState
					title={t('guest.claim.confirm.error.title')}
					body={t('guest.claim.confirm.error.body')}
				/>
			{/if}
		{/snippet}
	</ConfirmToken>
</PublicShell>
