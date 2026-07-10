import { describe, expect, it } from 'vitest';
import { safeHttpUrl } from './url.js';

describe('safeHttpUrl', () => {
	it('passes through http(s) URLs, including IDN hosts and pasted padding', () => {
		expect(safeHttpUrl('https://maps.example.com/x')).toBe('https://maps.example.com/x');
		expect(safeHttpUrl('http://example.com')).toBe('http://example.com');
		expect(safeHttpUrl('https://øl.dk')).toBe('https://øl.dk');
		expect(safeHttpUrl('https://example.com ')).toBe('https://example.com ');
	});

	it('rejects executable and scheme-less forms, and empty values', () => {
		expect(safeHttpUrl('javascript:alert(1)')).toBeNull();
		expect(safeHttpUrl('data:text/html,x')).toBeNull();
		expect(safeHttpUrl('//example.com')).toBeNull();
		expect(safeHttpUrl('https:example.com')).toBeNull();
		expect(safeHttpUrl(null)).toBeNull();
		expect(safeHttpUrl('')).toBeNull();
	});
});
