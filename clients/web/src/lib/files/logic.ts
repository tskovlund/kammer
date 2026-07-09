import type { LibraryFile } from './types.js';

/**
 * Human-readable byte size, base-1024. One decimal below 10 units, whole
 * numbers above — so "3.4 MB" but "812 KB" and "1.2 GB". Deliberately
 * locale-agnostic: file sizes read the same in every language.
 */
export function formatBytes(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes < 0) return '';
	if (bytes < 1024) return `${bytes} B`;

	const units = ['KB', 'MB', 'GB', 'TB'];
	let value = bytes / 1024;
	let unit = 0;
	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit += 1;
	}

	const rendered = value < 10 ? value.toFixed(1) : String(Math.round(value));
	return `${rendered} ${units[unit]}`;
}

/** Whether the file is a (thumbnailable) image. */
export function isImage(file: { kind: string }): boolean {
	return file.kind === 'image';
}

/**
 * Whether the library should offer a delete affordance for this file: the
 * caller's own upload or a space manager, AND it's a real library entry.
 * Entry-less files (`file_entry_id == null`) are feed/comment attachments
 * that merely surface in the "Feed uploads" system folder — they're owned by
 * their post, and deleting one here cascades it out of that post, so the
 * library doesn't offer it (delete the post instead). Advisory only — the
 * server enforces permissions regardless; this just drives the UI.
 */
export function canDeleteFile(
	file: Pick<LibraryFile, 'mine' | 'file_entry_id'>,
	canManage: boolean
): boolean {
	return (file.mine || canManage) && file.file_entry_id != null;
}
