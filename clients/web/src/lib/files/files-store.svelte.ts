import { FeedApiError, type FeedErrorKind } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import * as api from './api.js';
import type { FileListing, Folder, LibraryFile } from './types.js';

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

interface Ref {
	community: string;
	group: string;
}

/**
 * One group's file library, live-in-memory. Browsing is load-on-mount per
 * folder (there is no realtime channel for files): opening a folder refetches
 * that folder's listing, so the breadcrumb chain and capability flags always
 * come from the server. Writes (upload, new version, folder create/delete,
 * override, delete) call the context endpoint then refetch the current folder,
 * so the view is never guessed. Every failure lands in `actionError` for a
 * dismissible banner; the version sheet keeps its own `detail`.
 */
export function createFilesStore(instance: Instance, ref: Ref) {
	let listing = $state<FileListing | null>(null);
	let folderId = $state<string | null>(null);
	let loadState = $state<LoadState>('idle');
	let loadErrorKind = $state<FeedErrorKind | null>(null);
	let actionError = $state<{ message: string; kind: FeedErrorKind } | null>(null);
	let busy = $state(false);
	let detail = $state<LibraryFile | null>(null);
	// Discards a listing fetch that resolves after a newer navigation, so an
	// older folder never overwrites the one the user is now looking at.
	let generation = 0;

	function report(error: unknown): void {
		if (error instanceof FeedApiError) actionError = { message: error.message, kind: error.kind };
		else actionError = { message: 'Something went wrong.', kind: 'server' };
	}

	async function load(target: string | null = folderId): Promise<void> {
		const mine = ++generation;
		folderId = target;
		loadState = 'loading';
		loadErrorKind = null;
		try {
			const next = await api.fetchListing(instance, ref, target);
			if (mine !== generation) return;
			listing = next;
			loadState = 'ready';
		} catch (error) {
			if (mine !== generation) return;
			loadErrorKind = error instanceof FeedApiError ? error.kind : 'server';
			loadState = 'error';
		}
	}

	function openFolder(folder: Folder): Promise<void> {
		return load(folder.id);
	}

	function navigateTo(target: string | null): Promise<void> {
		return load(target);
	}

	async function upload(file: File): Promise<boolean> {
		busy = true;
		try {
			await api.uploadFile(instance, ref, file, { folderId });
			await load();
			return true;
		} catch (error) {
			report(error);
			return false;
		} finally {
			busy = false;
		}
	}

	async function addFolder(name: string): Promise<boolean> {
		try {
			await api.createFolder(instance, ref, name, folderId);
			await load();
			return true;
		} catch (error) {
			report(error);
			return false;
		}
	}

	async function removeFile(file: LibraryFile): Promise<void> {
		try {
			await api.deleteFile(instance, ref, file.id);
			if (detail?.id === file.id) detail = null;
			await load();
		} catch (error) {
			report(error);
		}
	}

	async function removeFolder(folder: Folder): Promise<void> {
		try {
			await api.deleteFolder(instance, ref, folder.id);
			await load();
		} catch (error) {
			report(error);
		}
	}

	async function setOverrides(
		folder: Folder,
		overrides: {
			read_override?: Folder['read_override'];
			write_override?: Folder['write_override'];
		}
	): Promise<void> {
		try {
			await api.updateFolderOverrides(instance, ref, folder.id, overrides);
			await load();
		} catch (error) {
			report(error);
		}
	}

	async function openVersions(file: LibraryFile): Promise<void> {
		// Show what we have immediately, then fetch the full history.
		detail = file;
		try {
			detail = await api.fetchFile(instance, ref, file.id);
		} catch (error) {
			report(error);
		}
	}

	function closeVersions(): void {
		detail = null;
	}

	async function uploadVersion(file: File): Promise<boolean> {
		if (!detail) return false;
		busy = true;
		try {
			detail = await api.uploadFile(instance, ref, file, { fileId: detail.id });
			await load();
			return true;
		} catch (error) {
			report(error);
			return false;
		} finally {
			busy = false;
		}
	}

	async function removeVersion(versionId: string): Promise<void> {
		if (!detail) return;
		try {
			await api.deleteVersion(instance, ref, detail.id, versionId);
			detail = await api.fetchFile(instance, ref, detail.id);
			await load();
		} catch (error) {
			report(error);
		}
	}

	return {
		get folders(): Folder[] {
			return listing?.folders ?? [];
		},
		get files(): LibraryFile[] {
			return listing?.files ?? [];
		},
		get chain(): Folder[] {
			return listing?.chain ?? [];
		},
		get folder(): Folder | null {
			return listing?.folder ?? null;
		},
		get canWrite(): boolean {
			return listing?.can_write ?? false;
		},
		get canManage(): boolean {
			return listing?.can_manage ?? false;
		},
		get isEmpty(): boolean {
			return (listing?.folders.length ?? 0) === 0 && (listing?.files.length ?? 0) === 0;
		},
		get loadState() {
			return loadState;
		},
		get loadErrorKind() {
			return loadErrorKind;
		},
		get actionError() {
			return actionError;
		},
		get busy() {
			return busy;
		},
		get detail() {
			return detail;
		},
		clearActionError() {
			actionError = null;
		},
		load,
		openFolder,
		navigateTo,
		upload,
		addFolder,
		removeFile,
		removeFolder,
		setOverrides,
		openVersions,
		closeVersions,
		uploadVersion,
		removeVersion,
		stop() {
			generation += 1;
		}
	};
}

export type FilesStore = ReturnType<typeof createFilesStore>;
