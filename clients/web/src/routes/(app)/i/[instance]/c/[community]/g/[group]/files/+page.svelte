<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchAuthedObjectUrl, FeedApiError, fetchGroup, type Group } from '$lib/feed/api.js';
	import { createFilesStore, type FilesStore } from '$lib/files/files-store.svelte.js';
	import FolderMenu from '$lib/files/components/FolderMenu.svelte';
	import VersionSheet from '$lib/files/components/VersionSheet.svelte';
	import type { Folder, LibraryFile } from '$lib/files/types.js';
	import { canDeleteFile, formatBytes, isImage } from '$lib/files/logic.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import AuthedImage from '$lib/ui/AuthedImage.svelte';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let store = $state<FilesStore | null>(null);
	let group = $state<Group | null>(null);
	let metaError = $state<FeedErrorKind | null>(null);
	let fileInput = $state<HTMLInputElement>();
	let creatingFolder = $state(false);
	let newFolderName = $state('');

	type FeedErrorKind = FeedApiError['kind'];

	// Resolve the group (name + files-feature gate happen server-side), build
	// the store, and load the root. Re-runs on instance/route change; the
	// cleanup discards a late listing fetch so folders don't cross-contaminate.
	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !communitySlug || !groupSlug) return;

		let cancelled = false;
		let localStore: FilesStore | null = null;
		store = null;
		group = null;
		metaError = null;

		(async () => {
			try {
				const resolved = await fetchGroup(inst, communitySlug, groupSlug);
				if (cancelled) return;
				group = resolved;
				localStore = createFilesStore(inst, { community: communitySlug, group: groupSlug });
				store = localStore;
				await localStore.load(null);
			} catch (error) {
				if (!cancelled) metaError = error instanceof FeedApiError ? error.kind : 'server';
			}
		})();

		return () => {
			cancelled = true;
			localStore?.stop();
		};
	});

	const groupHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}`)
	);

	async function onPick(event: Event): Promise<void> {
		const input = event.currentTarget as HTMLInputElement;
		const file = input.files?.[0];
		input.value = '';
		if (file && store) await store.upload(file);
	}

	async function submitFolder(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		const name = newFolderName.trim();
		if (!name || !store) return;
		const ok = await store.addFolder(name);
		if (ok) {
			newFolderName = '';
			creatingFolder = false;
		}
	}

	async function download(file: LibraryFile): Promise<void> {
		if (!instance) return;
		try {
			const objectUrl = await fetchAuthedObjectUrl(instance, file.download_url);
			const anchor = document.createElement('a');
			anchor.href = objectUrl;
			anchor.download = file.filename;
			anchor.rel = 'noopener';
			document.body.appendChild(anchor);
			anchor.click();
			anchor.remove();
			URL.revokeObjectURL(objectUrl);
		} catch {
			/* store surfaces errors elsewhere; a failed download is silent */
		}
	}

	function toggleOverride(folder: Folder, axis: 'read_override' | 'write_override'): void {
		const next = folder[axis] === 'admins_only' ? 'inherit' : 'admins_only';
		store?.setOverrides(folder, { [axis]: next });
	}
</script>

<svelte:head>
	<title>{t('files.title')} · {group?.name ?? t('nav.groups')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else if metaError}
	<EmptyState
		title={metaError === 'auth' ? t('feed.error.authTitle') : t('files.error.title')}
		body={metaError === 'auth' ? t('feed.error.authBody') : t('files.error.body')}
	/>
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={groupHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{group?.name ?? t('common.back')}
		</a>
		<h1 class="text-xl font-semibold tracking-tight text-ink">{t('files.title')}</h1>
	</header>

	{#if store}
		{#if store.chain.length > 0}
			<nav
				class="mb-4 flex flex-wrap items-center gap-1 text-sm"
				aria-label={t('files.breadcrumb')}
			>
				<button
					type="button"
					class="rounded px-1.5 py-0.5 text-ink-muted hover:bg-ink/5 hover:text-ink"
					onclick={() => store?.navigateTo(null)}
				>
					{t('files.root')}
				</button>
				{#each store.chain as crumb, index (crumb.id)}
					<span class="text-ink-faint" aria-hidden="true">/</span>
					{#if index === store.chain.length - 1}
						<span class="px-1.5 py-0.5 font-medium text-ink">{crumb.name}</span>
					{:else}
						<button
							type="button"
							class="rounded px-1.5 py-0.5 text-ink-muted hover:bg-ink/5 hover:text-ink"
							onclick={() => store?.navigateTo(crumb.id)}
						>
							{crumb.name}
						</button>
					{/if}
				{/each}
			</nav>
		{/if}

		{#if store.canWrite}
			<div class="mb-4 flex flex-wrap items-center gap-2">
				<input
					bind:this={fileInput}
					type="file"
					class="sr-only"
					aria-hidden="true"
					tabindex="-1"
					onchange={onPick}
				/>
				<Button
					variant="primary"
					size="sm"
					disabled={store.busy}
					onclick={() => fileInput?.click()}
				>
					{store.busy ? t('files.uploading') : t('files.upload')}
				</Button>
				{#if creatingFolder}
					<form class="flex items-center gap-2" onsubmit={submitFolder}>
						<!-- svelte-ignore a11y_autofocus -->
						<input
							bind:value={newFolderName}
							type="text"
							autofocus
							maxlength="100"
							placeholder={t('files.folderName')}
							class="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
						/>
						<Button type="submit" variant="secondary" size="sm">{t('common.save')}</Button>
						<Button
							variant="ghost"
							size="sm"
							onclick={() => {
								creatingFolder = false;
								newFolderName = '';
							}}
						>
							{t('common.cancel')}
						</Button>
					</form>
				{:else}
					<Button variant="secondary" size="sm" onclick={() => (creatingFolder = true)}>
						{t('files.newFolder')}
					</Button>
				{/if}
			</div>
		{/if}

		{#if store.actionError}
			<div
				class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				<span>{store.actionError.message}</span>
				<button
					type="button"
					class="shrink-0 text-danger/70 hover:text-danger"
					aria-label={t('common.dismiss')}
					onclick={() => store?.clearActionError()}
				>
					✕
				</button>
			</div>
		{/if}

		{#if store.loadState === 'loading'}
			<div class="flex flex-col gap-2">
				{#each [0, 1, 2, 3] as row (row)}
					<div class="flex items-center gap-3 rounded-xl border border-line bg-surface p-4">
						<Skeleton class="size-10 rounded-lg" />
						<Skeleton class="h-4 w-40" />
					</div>
				{/each}
			</div>
		{:else if store.loadState === 'error'}
			<EmptyState
				title={store.loadErrorKind === 'auth' ? t('feed.error.authTitle') : t('files.error.title')}
				body={store.loadErrorKind === 'auth' ? t('feed.error.authBody') : t('files.error.body')}
			>
				<Button variant="secondary" size="sm" onclick={() => store?.load()}>
					{t('common.retry')}
				</Button>
			</EmptyState>
		{:else if store.isEmpty}
			<EmptyState title={t('files.empty.title')} body={t('files.empty.body')}>
				{#snippet icon()}<TabIcon name="groups" class="size-8" />{/snippet}
			</EmptyState>
		{:else}
			<Card class="divide-y divide-line">
				{#each store.folders as folder (folder.id)}
					<div class="flex items-center gap-3 px-4 py-3">
						<button
							type="button"
							class="flex min-w-0 flex-1 items-center gap-3 text-left"
							onclick={() => store?.openFolder(folder)}
						>
							<span class="shrink-0 text-ink-muted">
								<svg
									viewBox="0 0 24 24"
									fill="none"
									stroke="currentColor"
									stroke-width="1.5"
									class="size-6"
								>
									<path
										stroke-linecap="round"
										stroke-linejoin="round"
										d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
									/>
								</svg>
							</span>
							<span class="min-w-0">
								<span class="block truncate text-sm font-medium text-ink">{folder.name}</span>
								{#if folder.read_override === 'admins_only' || folder.write_override === 'admins_only'}
									<span class="text-xs text-ink-faint">{t('files.restricted')}</span>
								{/if}
							</span>
						</button>
						{#if store.canManage && !folder.system}
							<FolderMenu
								{folder}
								onToggleRead={() => toggleOverride(folder, 'read_override')}
								onToggleWrite={() => toggleOverride(folder, 'write_override')}
								onDelete={() => store?.removeFolder(folder)}
							/>
						{/if}
					</div>
				{/each}

				{#each store.files as file (file.id)}
					<div class="flex items-center gap-3 px-4 py-3">
						<span class="shrink-0">
							{#if isImage(file) && file.thumbnail_url}
								<AuthedImage
									{instance}
									path={file.thumbnail_url}
									alt={file.filename}
									class="size-10 rounded-lg object-cover"
								/>
							{:else}
								<span
									class="flex size-10 items-center justify-center rounded-lg bg-paper text-ink-muted"
								>
									<svg
										viewBox="0 0 24 24"
										fill="none"
										stroke="currentColor"
										stroke-width="1.5"
										class="size-5"
									>
										<path
											stroke-linecap="round"
											stroke-linejoin="round"
											d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"
										/>
									</svg>
								</span>
							{/if}
						</span>
						<button
							type="button"
							class="min-w-0 flex-1 text-left"
							onclick={() => store?.openVersions(file)}
						>
							<span class="block truncate text-sm font-medium text-ink">{file.filename}</span>
							<span class="text-xs text-ink-muted">
								{formatBytes(file.byte_size)}
								{#if (file.version_seq ?? 1) > 1}
									· {t('files.versionsShort', { count: String(file.version_seq) })}
								{/if}
							</span>
						</button>
						<div class="flex shrink-0 items-center gap-1">
							<Button variant="ghost" size="sm" onclick={() => download(file)}>
								{t('files.download')}
							</Button>
							{#if canDeleteFile(file, store.canManage)}
								<button
									type="button"
									class="rounded-lg p-1.5 text-ink-muted hover:bg-danger/5 hover:text-danger"
									aria-label={t('files.deleteFile')}
									onclick={() => store?.removeFile(file)}
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
				{/each}
			</Card>
		{/if}

		<VersionSheet {store} {instance} />
	{/if}
{/if}
