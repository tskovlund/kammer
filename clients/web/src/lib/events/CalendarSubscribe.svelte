<script lang="ts">
	import { tick } from 'svelte';

	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import type { CalendarToken } from './api.js';

	interface Props {
		/** Fetches the subscription token — lazy, only on reveal (it mints the token). */
		load: () => Promise<CalendarToken>;
		/**
		 * Revokes the current link and mints a fresh one (#291). Only shown
		 * when provided — the personal calendar can reset its own link; a
		 * group's is a moderator action left to a separate surface.
		 */
		reset?: () => Promise<CalendarToken>;
		/** The reveal button's label (group vs. personal). */
		label: string;
		/** Id prefix for the reveal button and the revealed URL (tests, a11y). */
		id?: string;
	}
	let { load, reset, label, id = 'calendar-subscribe' }: Props = $props();

	let status = $state<'idle' | 'loading' | 'ready' | 'error'>('idle');
	let url = $state('');
	let copied = $state(false);
	let resetting = $state(false);
	let resetOutcome = $state<'none' | 'done' | 'error'>('none');
	// The revealed region takes focus so a keyboard/AT user lands on the new
	// content instead of the now-gone reveal button.
	let revealed = $state<HTMLElement>();

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
		'inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-3 text-xs font-medium text-accent-ink transition-colors duration-150 hover:bg-accent/90 active:bg-accent/80';

	async function reveal(): Promise<void> {
		if (status === 'loading' || status === 'ready') return;
		status = 'loading';
		try {
			url = (await load()).url;
			status = 'ready';
			await tick();
			revealed?.focus();
		} catch {
			status = 'error';
		}
	}

	async function copy(): Promise<void> {
		try {
			await navigator.clipboard?.writeText(url);
			copied = true;
			setTimeout(() => {
				copied = false;
			}, 2000);
		} catch {
			// No clipboard access — the URL stays selectable to copy by hand.
		}
	}

	async function resetLink(): Promise<void> {
		if (!reset || resetting) return;
		resetting = true;
		resetOutcome = 'none';
		try {
			// The old URL dies the moment the token rotates; swap in the new one
			// so the visible link and the copy button stay correct.
			url = (await reset()).url;
			resetOutcome = 'done';
		} catch {
			resetOutcome = 'error';
		} finally {
			resetting = false;
		}
	}
</script>

{#if status === 'ready'}
	<div bind:this={revealed} tabindex="-1" role="status" class="flex flex-col gap-2 outline-none">
		<p class="text-sm text-ink-muted">{t('events.subscribe.hint')}</p>
		<code {id} class={codeClass}>{url}</code>
		<div class="flex flex-wrap items-center gap-2">
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
			<a id="{id}-open" href={webcalUrl} class={openClass}>{t('events.subscribe.open')}</a>
			<Button id="{id}-copy" variant="ghost" size="sm" onclick={copy}>
				{copied ? t('events.subscribe.copied') : t('events.subscribe.copy')}
			</Button>
			{#if reset}
				<Button id="{id}-reset" variant="ghost" size="sm" disabled={resetting} onclick={resetLink}>
					{t('events.subscribe.reset')}
				</Button>
			{/if}
		</div>
		<!-- No own role="status": the enclosing region is already an atomic
		     live region and re-announces this line when it appears. -->
		{#if resetOutcome === 'done'}
			<p id="{id}-reset-status" class="text-xs text-ink-muted">
				{t('events.subscribe.resetDone')}
			</p>
		{:else if resetOutcome === 'error'}
			<p id="{id}-reset-status" class="text-xs text-danger">
				{t('events.subscribe.resetError')}
			</p>
		{/if}
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
