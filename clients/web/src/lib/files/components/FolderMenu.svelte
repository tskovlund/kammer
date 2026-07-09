<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { dismissable } from '$lib/ui/dismissable.js';
	import type { Folder } from '../types.js';

	interface Props {
		folder: Folder;
		onToggleRead: () => void;
		onToggleWrite: () => void;
		onDelete: () => void;
	}

	let { folder, onToggleRead, onToggleWrite, onDelete }: Props = $props();

	let open = $state(false);
	// Bound and passed to `dismissable` as the trigger so a click on this
	// button dismisses cleanly instead of the capture-phase pointerdown
	// closing the menu only for the click to reopen it (matches PostCard).
	let trigger = $state<HTMLButtonElement>();
</script>

<div class="relative shrink-0">
	<button
		bind:this={trigger}
		type="button"
		class="rounded-lg p-1.5 text-ink-muted hover:bg-ink/5 hover:text-ink"
		aria-label={t('files.folderMenu')}
		aria-expanded={open}
		onclick={() => (open = !open)}
	>
		<svg viewBox="0 0 24 24" fill="currentColor" class="size-5">
			<path
				d="M12 6.75a.75.75 0 110-1.5.75.75 0 010 1.5zM12 12.75a.75.75 0 110-1.5.75.75 0 010 1.5zM12 18.75a.75.75 0 110-1.5.75.75 0 010 1.5z"
			/>
		</svg>
	</button>
	{#if open}
		<div
			class="absolute right-0 z-20 mt-1 w-56 rounded-lg border border-line bg-surface py-1 shadow-lg"
			role="menu"
			use:dismissable={{ onDismiss: () => (open = false), trigger, arrowKeys: true }}
		>
			<button
				type="button"
				role="menuitem"
				class="block w-full px-3 py-2 text-left text-sm text-ink hover:bg-ink/5"
				onclick={() => {
					open = false;
					onToggleRead();
				}}
			>
				{folder.read_override === 'admins_only'
					? t('files.override.allowRead')
					: t('files.override.restrictRead')}
			</button>
			<button
				type="button"
				role="menuitem"
				class="block w-full px-3 py-2 text-left text-sm text-ink hover:bg-ink/5"
				onclick={() => {
					open = false;
					onToggleWrite();
				}}
			>
				{folder.write_override === 'admins_only'
					? t('files.override.allowWrite')
					: t('files.override.restrictWrite')}
			</button>
			<button
				type="button"
				role="menuitem"
				class="block w-full px-3 py-2 text-left text-sm text-danger hover:bg-danger/5"
				onclick={() => {
					open = false;
					onDelete();
				}}
			>
				{t('files.deleteFolder')}
			</button>
		</div>
	{/if}
</div>
