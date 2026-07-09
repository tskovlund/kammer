import { describe, expect, it } from 'vitest';
import { canDeleteFile, formatBytes, isImage } from './logic.js';

describe('formatBytes', () => {
	it('shows bytes below a kilobyte', () => {
		expect(formatBytes(0)).toBe('0 B');
		expect(formatBytes(512)).toBe('512 B');
		expect(formatBytes(1023)).toBe('1023 B');
	});

	it('scales into KB/MB/GB with one decimal below ten units', () => {
		expect(formatBytes(1024)).toBe('1.0 KB');
		expect(formatBytes(1536)).toBe('1.5 KB');
		expect(formatBytes(1024 * 1024)).toBe('1.0 MB');
		expect(formatBytes(3.4 * 1024 * 1024)).toBe('3.4 MB');
		expect(formatBytes(2 * 1024 * 1024 * 1024)).toBe('2.0 GB');
	});

	it('drops the decimal at ten units and above', () => {
		expect(formatBytes(12 * 1024)).toBe('12 KB');
		expect(formatBytes(812 * 1024)).toBe('812 KB');
	});

	it('is defensive about bad input', () => {
		expect(formatBytes(-1)).toBe('');
		expect(formatBytes(Number.NaN)).toBe('');
	});
});

describe('isImage', () => {
	it('is true only for the image kind', () => {
		expect(isImage({ kind: 'image' })).toBe(true);
		expect(isImage({ kind: 'file' })).toBe(false);
	});
});

describe('canDeleteFile', () => {
	it('lets the uploader or a manager delete a real library entry', () => {
		expect(canDeleteFile({ mine: true, file_entry_id: 'e1' }, false)).toBe(true);
		expect(canDeleteFile({ mine: false, file_entry_id: 'e1' }, true)).toBe(true);
		expect(canDeleteFile({ mine: false, file_entry_id: 'e1' }, false)).toBe(false);
	});

	it('never offers delete for an entry-less feed upload (owned by its post)', () => {
		// A feed/comment attachment surfacing in the "Feed uploads" folder:
		// deleting it here would cascade it out of its post, so the library
		// withholds the affordance even from its uploader or a manager.
		expect(canDeleteFile({ mine: true, file_entry_id: null }, true)).toBe(false);
		expect(canDeleteFile({ mine: true, file_entry_id: null }, false)).toBe(false);
	});
});
