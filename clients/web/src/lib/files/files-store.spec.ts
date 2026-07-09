import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { FileListing, Folder, LibraryFile } from './types.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return {
		...actual,
		fetchListing: vi.fn(),
		fetchFile: vi.fn(),
		uploadFile: vi.fn(),
		createFolder: vi.fn(),
		deleteFile: vi.fn(),
		deleteFolder: vi.fn(),
		deleteVersion: vi.fn(),
		updateFolderOverrides: vi.fn()
	};
});

import * as api from './api.js';
import { createFilesStore } from './files-store.svelte.js';

function instance(): Instance {
	return {
		id: 'i',
		baseUrl: 'https://i.example',
		instanceName: 'I',
		deviceToken: 't',
		user: { id: 'u', email: 'a@a', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function folder(id: string, name: string): Folder {
	return {
		id,
		name,
		parent_folder_id: null,
		read_override: 'inherit',
		write_override: 'inherit',
		system: false
	};
}

function file(id: string, filename: string): LibraryFile {
	return {
		id,
		file_entry_id: `${id}-entry`,
		folder_id: null,
		filename,
		content_type: 'text/plain',
		byte_size: 10,
		kind: 'file',
		width: null,
		height: null,
		version_seq: 1,
		uploaded_at: '2026-01-01T00:00:00Z',
		uploaded_by: { type: 'user', id: 'u', display_name: 'A' },
		mine: true,
		url: `/api/v1/files/${id}`,
		thumbnail_url: null,
		download_url: `/api/v1/files/${id}/download`,
		versions: []
	};
}

function listing(over: Partial<FileListing> = {}): FileListing {
	return {
		folder: null,
		chain: [],
		folders: [],
		files: [],
		can_write: true,
		can_manage: false,
		...over
	};
}

const mockListing = vi.mocked(api.fetchListing);
const mockFile = vi.mocked(api.fetchFile);
const mockUpload = vi.mocked(api.uploadFile);
const mockDeleteFile = vi.mocked(api.deleteFile);
const mockDeleteVersion = vi.mocked(api.deleteVersion);

const ref = { community: 'c', group: 'g' };

beforeEach(() => {
	vi.clearAllMocks();
});

describe('createFilesStore', () => {
	it('loads a folder into folders/files/chain and capabilities', async () => {
		mockListing.mockResolvedValue(
			listing({ folders: [folder('f1', 'Scores')], files: [file('a', 'a.txt')], can_manage: true })
		);

		const store = createFilesStore(instance(), ref);
		await store.load(null);

		expect(store.loadState).toBe('ready');
		expect(store.folders.map((f) => f.name)).toEqual(['Scores']);
		expect(store.files.map((f) => f.filename)).toEqual(['a.txt']);
		expect(store.canWrite).toBe(true);
		expect(store.canManage).toBe(true);
		expect(store.isEmpty).toBe(false);
	});

	it('openFolder requests that folder by id', async () => {
		mockListing.mockResolvedValue(listing());
		const store = createFilesStore(instance(), ref);

		await store.openFolder(folder('f9', 'Sub'));

		expect(mockListing).toHaveBeenLastCalledWith(expect.anything(), ref, 'f9');
	});

	it('a stale load never overwrites a newer one (generation guard)', async () => {
		let resolveFirst: (value: FileListing) => void = () => {};
		const first = new Promise<FileListing>((resolve) => (resolveFirst = resolve));
		mockListing
			.mockReturnValueOnce(first)
			.mockResolvedValueOnce(listing({ folders: [folder('new', 'New')] }));

		const store = createFilesStore(instance(), ref);
		const firstLoad = store.load('old');
		const secondLoad = store.load(null);
		await secondLoad;
		// The first (older) fetch resolves last, but must be discarded.
		resolveFirst(listing({ folders: [folder('old', 'Old')] }));
		await firstLoad;

		expect(store.folders.map((f) => f.name)).toEqual(['New']);
	});

	it('upload posts then reloads the current folder', async () => {
		mockListing.mockResolvedValue(listing());
		mockUpload.mockResolvedValue(file('new', 'new.txt'));
		const store = createFilesStore(instance(), ref);
		await store.load('folder-1');
		mockListing.mockClear();

		const ok = await store.upload(new File(['x'], 'new.txt'));

		expect(ok).toBe(true);
		expect(mockUpload).toHaveBeenCalledWith(expect.anything(), ref, expect.any(File), {
			folderId: 'folder-1'
		});
		expect(mockListing).toHaveBeenLastCalledWith(expect.anything(), ref, 'folder-1');
	});

	it('surfaces a write failure as a dismissible action error', async () => {
		mockListing.mockResolvedValue(listing());
		mockDeleteFile.mockRejectedValue(new FeedApiError('forbidden', 'Nope', 403));
		const store = createFilesStore(instance(), ref);
		await store.load(null);

		await store.removeFile(file('a', 'a.txt'));

		expect(store.actionError).toEqual({ message: 'Nope', kind: 'forbidden' });
		store.clearActionError();
		expect(store.actionError).toBeNull();
	});

	it('openVersions fetches the full detail with history', async () => {
		mockListing.mockResolvedValue(listing());
		const withHistory = { ...file('a', 'a.txt'), versions: [] };
		mockFile.mockResolvedValue(withHistory);
		const store = createFilesStore(instance(), ref);
		await store.load(null);

		await store.openVersions(file('a', 'a.txt'));

		expect(mockFile).toHaveBeenCalledWith(expect.anything(), ref, 'a');
		expect(store.detail?.id).toBe('a');
		store.closeVersions();
		expect(store.detail).toBeNull();
	});

	it('deleting the current version refetches by a surviving id, not the deleted one', async () => {
		mockListing.mockResolvedValue(listing());
		// The head version's id equals the file's id; deleting it must not
		// refetch by that (now-gone) id, or the server 404s and the sheet
		// shows a spurious error over a delete that actually succeeded.
		const detail = {
			...file('a', 'a.txt'),
			versions: [
				{ id: 'a', version_seq: 2, current: true } as never,
				{ id: 'a0', version_seq: 1, current: false } as never
			]
		};
		mockFile.mockResolvedValueOnce(detail);
		const store = createFilesStore(instance(), ref);
		await store.load(null);
		await store.openVersions(file('a', 'a.txt'));

		mockDeleteVersion.mockResolvedValueOnce(undefined as never);
		mockFile.mockResolvedValueOnce({ ...file('a0', 'a.txt'), id: 'a0' });
		await store.removeVersion('a');

		// Refetched by the survivor 'a0', and no error was surfaced.
		expect(mockDeleteVersion).toHaveBeenCalledWith(expect.anything(), ref, 'a', 'a');
		expect(mockFile).toHaveBeenLastCalledWith(expect.anything(), ref, 'a0');
		expect(store.actionError).toBeNull();
	});
});
