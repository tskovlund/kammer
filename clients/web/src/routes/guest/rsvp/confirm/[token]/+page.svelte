<script lang="ts">
	import { page } from '$app/state';
	import { confirmGuestRsvp } from '$lib/guest/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import ConfirmToken from '$lib/ui/ConfirmToken.svelte';
</script>

<svelte:head><title>{t('guest.rsvp.confirm.title')} · {t('app.name')}</title></svelte:head>

<PublicShell>
	<ConfirmToken
		token={page.params.token}
		confirm={confirmGuestRsvp}
		loadingLabel={t('guest.rsvp.confirm.title')}
		errorTitle={t('guest.rsvp.confirm.error.title')}
		errorBody={t('guest.rsvp.confirm.error.body')}
	>
		{#snippet success({ guest_name })}
			<EmptyState
				title={t('guest.rsvp.confirm.success.title')}
				body={guest_name
					? t('guest.rsvp.confirm.success.bodyNamed', { name: guest_name })
					: t('guest.rsvp.confirm.success.body')}
			/>
		{/snippet}
	</ConfirmToken>
</PublicShell>
