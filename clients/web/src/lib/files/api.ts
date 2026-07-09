import { createApiClient } from '$lib/api/client.js';
import { FeedApiError, type FeedErrorKind } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { FileListing, Folder, LibraryFile } from './types.js';

function kindForStatus(status: number): FeedErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 413:
			return 'too_large';
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string };
}

function fail(error: unknown, response: Response | undefined, fallback: string): FeedApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const message = (error as ErrorEnvelope | undefined)?.error?.message ?? fallback;
	return new FeedApiError(kind, message, status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof FeedApiError) throw cause;
		throw new FeedApiError('network', 'Could not reach this community.', null);
	}
}

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

interface Ref {
	community: string;
	group: string;
}

export async function fetchListing(
	instance: Instance,
	ref: Ref,
	folderId: string | null
): Promise<FileListing> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/files',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group },
					query: folderId ? { folder_id: folderId } : {}
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not load files.');
		return data.data;
	});
}

export async function fetchFile(
	instance: Instance,
	ref: Ref,
	fileId: string
): Promise<LibraryFile> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, file_id: fileId }
				}
			}
		);
		if (error || !data) throw fail(error, response, 'Could not load this file.');
		return data.data;
	});
}

export async function createFolder(
	instance: Instance,
	ref: Ref,
	name: string,
	parentFolderId: string | null
): Promise<Folder> {
	return guard(async () => {
		const { data, error, response } = await client(instance).POST(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/folders',
			{
				params: { path: { community_slug: ref.community, group_slug: ref.group } },
				body: { name, parent_folder_id: parentFolderId }
			}
		);
		if (error || !data) throw fail(error, response, 'Could not create this folder.');
		return data.data;
	});
}

export async function updateFolderOverrides(
	instance: Instance,
	ref: Ref,
	folderId: string,
	overrides: {
		read_override?: 'inherit' | 'admins_only';
		write_override?: 'inherit' | 'admins_only';
	}
): Promise<Folder> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/folders/{folder_id}/overrides',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, folder_id: folderId }
				},
				body: overrides
			}
		);
		if (error || !data) throw fail(error, response, 'Could not update this folder.');
		return data.data;
	});
}

export async function deleteFolder(instance: Instance, ref: Ref, folderId: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/folders/{folder_id}',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, folder_id: folderId }
				}
			}
		);
		if (error) throw fail(error, response, 'Could not delete this folder.');
	});
}

export async function deleteFile(instance: Instance, ref: Ref, fileId: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}',
			{
				params: {
					path: { community_slug: ref.community, group_slug: ref.group, file_id: fileId }
				}
			}
		);
		if (error) throw fail(error, response, 'Could not delete this file.');
	});
}

export async function deleteVersion(
	instance: Instance,
	ref: Ref,
	fileId: string,
	versionId: string
): Promise<void> {
	return guard(async () => {
		const { error, response } = await client(instance).DELETE(
			'/api/v1/communities/{community_slug}/groups/{group_slug}/files/{file_id}/versions/{version_id}',
			{
				params: {
					path: {
						community_slug: ref.community,
						group_slug: ref.group,
						file_id: fileId,
						version_id: versionId
					}
				}
			}
		);
		if (error) throw fail(error, response, 'Could not delete this version.');
	});
}

/**
 * Upload a new file (or a new version of `fileId`) as multipart. openapi-fetch
 * doesn't own multipart well, so — like the feed composer's upload — we drive
 * `fetch` directly to keep the status code (413 is a distinct, friendly error)
 * and the auth header.
 */
export async function uploadFile(
	instance: Instance,
	ref: Ref,
	file: File,
	options: { folderId?: string | null; fileId?: string } = {}
): Promise<LibraryFile> {
	return guard(async () => {
		const form = new FormData();
		form.append('file', file);
		if (options.folderId) form.append('folder_id', options.folderId);

		const base =
			`${instance.baseUrl.replace(/\/$/, '')}` +
			`/api/v1/communities/${encodeURIComponent(ref.community)}` +
			`/groups/${encodeURIComponent(ref.group)}/files`;
		const url = options.fileId ? `${base}/${encodeURIComponent(options.fileId)}/versions` : base;

		let response: Response;
		try {
			response = await fetch(url, {
				method: 'POST',
				headers: { authorization: `Bearer ${instance.deviceToken}` },
				body: form
			});
		} catch {
			throw new FeedApiError('network', 'Could not reach this community.', null);
		}

		if (!response.ok) {
			let body: unknown = undefined;
			try {
				body = await response.json();
			} catch {
				/* non-JSON error body */
			}
			throw fail(body, response, 'Could not upload that file.');
		}

		const payload = (await response.json()) as { data: LibraryFile };
		return payload.data;
	});
}
