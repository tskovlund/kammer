import { describe, expect, it } from 'vitest';
import { extractMagicToken, normalizeInstanceUrl } from './signin';

describe('normalizeInstanceUrl', () => {
	it('adds https:// to a bare hostname', () => {
		expect(normalizeInstanceUrl('klub.example.dk')).toBe('https://klub.example.dk');
	});

	it('keeps an explicit scheme and strips paths and trailing slashes down to the origin', () => {
		expect(normalizeInstanceUrl('https://klub.example.dk/some/path/')).toBe(
			'https://klub.example.dk'
		);
	});

	it('trims surrounding whitespace', () => {
		expect(normalizeInstanceUrl('  klub.example.dk  ')).toBe('https://klub.example.dk');
	});

	it('preserves an explicit port', () => {
		expect(normalizeInstanceUrl('http://localhost:4000')).toBe('http://localhost:4000');
	});

	it('rejects empty input', () => {
		expect(normalizeInstanceUrl('   ')).toBeNull();
	});

	it('rejects input that cannot be a hostname', () => {
		expect(normalizeInstanceUrl('not a url')).toBeNull();
		expect(normalizeInstanceUrl('just-a-word')).toBeNull();
	});
});

describe('extractMagicToken', () => {
	it('extracts the token from a pasted /users/log-in/{token} magic link', () => {
		expect(extractMagicToken('https://klub.example.dk/users/log-in/abc123DEF-_x')).toBe(
			'abc123DEF-_x'
		);
	});

	it('extracts the token from a magic link with a trailing slash', () => {
		expect(extractMagicToken('https://klub.example.dk/users/log-in/abc123/')).toBe('abc123');
	});

	it('extracts the token from this client’s own /sign-in/{token} deep link', () => {
		expect(extractMagicToken('https://klub.example.dk/sign-in/abc123')).toBe('abc123');
	});

	it('accepts a bare token', () => {
		expect(extractMagicToken('  abc123DEF-_x  ')).toBe('abc123DEF-_x');
	});

	it('rejects a URL without a token path', () => {
		expect(extractMagicToken('https://klub.example.dk/users/settings')).toBeNull();
	});

	it('rejects free text that cannot be a token', () => {
		expect(extractMagicToken('open the email and click the link')).toBeNull();
	});

	it('rejects empty input', () => {
		expect(extractMagicToken('')).toBeNull();
	});
});
