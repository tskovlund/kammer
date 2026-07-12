<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import type { CalendarToken } from './api.js';

	interface Props {
		/** Fetches the subscription token — lazy, only on reveal (it mints the token). */
		load: () => Promise<CalendarToken>;
		/** The reveal button's label (group vs. personal). */
		label: string;
		/** Id prefix for the reveal button and the revealed URL (tests, a11y). */
		id?: string;
	}
	let { load, label, id = 'calendar-subscribe' }: Props = $props();

	let status = $state<'idle' | 'loading' | 'ready' | 'error'>('idle');
	let url = $state('');
	let copied = $state(false);

	// A `webcal://` link opens straight in most calendar apps; the copyable
	// https URL is the fallback for apps that want it pasted.
	const webcalUrl = $derived(url.replace(/^https?:/, 'webcal:'));

	// Kept in the script so each element's opening tag stays on one line —
	// prettier must not wrap the `<code>` (stray whitespace would ride along
	// in the select-all copy) or split the external href from its
	// lint-suppression comment.
	const codeClass =
		'select-all break-all rounded-lg border border-line bg-paper px-3 py-2 text-xs text-ink';
	const openClass =
		'inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-3 text-sm font-medium text-accent-ink transition-colors duration-150 hover:bg-accent/90 active:bg-accent/80';

	async function reveal(): Promise<void> {
		if (status === 'loading' || status === 'ready') return;
		status = 'loading';
		try {
			url = (await load()).url;
			status = 'ready';
		} catch {
			status = 'error';
		}
	}

	async function copy(): Promise<void> {
		try {
			await navigator.clipboard?.writeText(url);
			copied = true;
		} catch {
			// No clipboard access — the URL stays selectable to copy by hand.
		}
	}
</script>

{#if status === 'ready'}
	<div class="flex flex-col gap-2">
		<p class="text-sm text-ink-muted">{t('events.subscribe.hint')}</p>
		<code {id} class={codeClass}>{url}</code>
		<div class="flex flex-wrap items-center gap-2">
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
			<a href={webcalUrl} class={openClass}>{t('events.subscribe.open')}</a>
			<Button variant="ghost" size="sm" onclick={copy}>
				{copied ? t('events.subscribe.copied') : t('events.subscribe.copy')}
			</Button>
		</div>
	</div>
{:else}
	<Button
		id="{id}-reveal"
		variant="secondary"
		size="sm"
		disabled={status === 'loading'}
		onclick={reveal}
	>
		{status === 'error' ? t('events.subscribe.error') : label}
	</Button>
{/if}
