import { describe, expect, it } from 'vitest';
import { detectLocale, translate } from './format';

describe('translate', () => {
	it('returns the English message for en', () => {
		expect(translate('en', 'nav.home')).toBe('Home');
	});

	it('returns the Danish message for da', () => {
		expect(translate('da', 'nav.home')).toBe('Hjem');
	});

	it('interpolates {name} params', () => {
		expect(translate('en', 'you.accounts.signedInAs', { email: 'a@example.com' })).toBe(
			'Signed in as a@example.com'
		);
	});

	it('interpolates params in Danish messages too', () => {
		expect(translate('da', 'you.accounts.signedInAs', { email: 'a@example.com' })).toBe(
			'Logget ind som a@example.com'
		);
	});

	it('leaves an unknown placeholder literal rather than injecting undefined', () => {
		expect(translate('en', 'you.accounts.signedInAs', { wrong: 'x' })).toBe('Signed in as {email}');
	});
});

describe('detectLocale', () => {
	it('picks Danish for a da-DK browser', () => {
		expect(detectLocale(['da-DK', 'en-US'])).toBe('da');
	});

	it('picks Danish for a bare da tag', () => {
		expect(detectLocale(['da'])).toBe('da');
	});

	it('falls back to English for unsupported languages', () => {
		expect(detectLocale(['de-DE', 'fr'])).toBe('en');
	});

	it('falls back to English for an empty preference list', () => {
		expect(detectLocale([])).toBe('en');
	});
});
