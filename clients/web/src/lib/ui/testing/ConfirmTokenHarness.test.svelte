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

	// Snippets can only be authored in template syntax, so `ConfirmToken`'s
	// unit tests render it through this thin harness rather than passing a
	// hand-rolled snippet function (which would have to reimplement Svelte's
	// internal anchor-node calling convention).
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
</ConfirmToken>
