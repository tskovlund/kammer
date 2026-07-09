<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import { claimedByMe, slotHasRoom } from '../event-logic.js';
	import type { EventStore } from '../event-store.svelte.js';
	import type { Event } from '../types.js';

	interface Props {
		event: Event;
		store: EventStore;
		currentUserId: string;
	}

	let { event, store, currentUserId }: Props = $props();

	// #199: the API exposes no per-viewer capabilities, so organizer tools
	// (add/delete slots) can't be hidden from non-organizers — they're kept
	// behind a disclosure and fail closed with a toast on submit (403).
	let showManage = $state(false);
	let newTitle = $state('');
	let newCapacity = $state(1);
	let adding = $state(false);

	async function addSlot(submitEvent: SubmitEvent): Promise<void> {
		submitEvent.preventDefault();
		if (newTitle.trim().length === 0 || adding) return;
		adding = true;
		const ok = await store.addSlot({ title: newTitle.trim(), capacity: Math.max(1, newCapacity) });
		adding = false;
		if (ok) {
			newTitle = '';
			newCapacity = 1;
		}
	}
</script>

<section class="flex flex-col gap-3">
	<div class="flex items-center justify-between">
		<h2 class="text-sm font-semibold text-ink">{t('events.slots.title')}</h2>
		<button
			type="button"
			class="text-xs text-ink-faint hover:text-ink-muted"
			aria-expanded={showManage}
			onclick={() => (showManage = !showManage)}
		>
			{t('events.slots.organizerTools')}
		</button>
	</div>

	{#if event.slots.length === 0}
		<p class="text-sm text-ink-faint">{t('events.slots.empty')}</p>
	{/if}

	<ul class="flex flex-col gap-2">
		{#each event.slots as slot (slot.id)}
			{@const mine = claimedByMe(slot, currentUserId)}
			{@const room = slotHasRoom(slot)}
			<li class="flex flex-col gap-1.5 rounded-lg border border-line bg-surface p-3">
				<div class="flex items-center justify-between gap-3">
					<div class="min-w-0">
						<p class="truncate font-medium text-ink">{slot.title}</p>
						<p class="text-xs text-ink-faint">
							{t('events.slots.capacity', {
								taken: String(slot.taken),
								capacity: String(slot.capacity)
							})}
						</p>
					</div>
					<div class="flex shrink-0 items-center gap-2">
						{#if mine}
							<Button variant="secondary" size="sm" onclick={() => store.claimSlot(slot.id, false)}>
								{t('events.slots.release')}
							</Button>
						{:else if room}
							<Button variant="primary" size="sm" onclick={() => store.claimSlot(slot.id, true)}>
								{t('events.slots.claim')}
							</Button>
						{:else}
							<span class="text-xs font-medium text-ink-faint">{t('events.slots.full')}</span>
						{/if}
						{#if showManage}
							<button
								type="button"
								class="text-ink-faint hover:text-danger"
								aria-label={t('events.slots.delete')}
								onclick={() => store.removeSlot(slot.id)}
							>
								<svg
									viewBox="0 0 24 24"
									fill="none"
									stroke="currentColor"
									stroke-width="1.5"
									class="size-4"
								>
									<path
										stroke-linecap="round"
										stroke-linejoin="round"
										d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"
									/>
								</svg>
							</button>
						{/if}
					</div>
				</div>
				{#if slot.claimants && slot.claimants.length > 0}
					<p class="text-xs text-ink-muted">
						{slot.claimants
							.map((claimant) => claimant?.display_name)
							.filter(Boolean)
							.join(', ')}
					</p>
				{/if}
			</li>
		{/each}
	</ul>

	{#if showManage}
		<form
			onsubmit={addSlot}
			class="flex flex-col gap-2 rounded-lg border border-dashed border-line p-3"
		>
			<div class="flex flex-col gap-2 sm:flex-row">
				<input
					bind:value={newTitle}
					placeholder={t('events.slots.newTitle')}
					aria-label={t('events.slots.newTitle')}
					class="flex-1 rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink placeholder:text-ink-faint focus-visible:border-accent"
				/>
				<input
					type="number"
					min="1"
					bind:value={newCapacity}
					aria-label={t('events.slots.newCapacity')}
					class="w-24 rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink focus-visible:border-accent"
				/>
			</div>
			<Button
				type="submit"
				variant="secondary"
				size="sm"
				disabled={newTitle.trim().length === 0 || adding}
			>
				{adding ? t('common.sending') : t('events.slots.add')}
			</Button>
		</form>
	{/if}
</section>
