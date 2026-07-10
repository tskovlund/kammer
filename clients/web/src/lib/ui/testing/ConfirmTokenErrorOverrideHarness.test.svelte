<script lang="ts">
	import ConfirmToken from '../ConfirmToken.svelte';

	interface Confirmation {
		guest_name: string | null;
		redirect_path: string;
	}

	interface Props {
		token: string | undefined;
		confirm: (baseUrl: string, token: string) => Promise<Confirmation>;
	}

	// Covers the `error` snippet override the claim confirm page uses to
	// distinguish a full slot (422) from a plain invalid/expired token (404).
	let { token, confirm }: Props = $props();
</script>

<ConfirmToken
	{token}
	{confirm}
	loadingLabel="Confirming…"
	errorTitle="That link didn't work"
	errorBody="This link is no longer valid."
>
	{#snippet success({ guest_name })}
		<p>Hi {guest_name ?? 'guest'}</p>
	{/snippet}
	{#snippet error(caught)}
		<p>custom: {caught instanceof Error ? caught.message : 'unknown'}</p>
	{/snippet}
</ConfirmToken>
