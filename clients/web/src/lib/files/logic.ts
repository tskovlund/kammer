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
 * Whether the caller may delete this file: their own upload, or a space
 * manager. Advisory only — the server enforces it regardless; this drives
 * which affordances the UI offers.
 */
export function canDeleteFile(file: Pick<LibraryFile, 'mine'>, canManage: boolean): boolean {
	return file.mine || canManage;
}
