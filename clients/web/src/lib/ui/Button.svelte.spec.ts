import { afterEach, describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import ButtonHarness from './testing/ButtonHarness.test.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

describe('Button', () => {
	// The href branch renders an <a> with the same look; it used to pass
	// through only `id`, silently dropping aria-*/data-*/target — a foot-gun
	// for the next caller (#316).
	it('forwards rest props on the link (href) variant', () => {
		render(ButtonHarness, {
			props: { href: '/x', 'aria-label': 'Add to calendar', 'data-testid': 'cta', target: '_blank' }
		});

		const link = screen.getByRole('link', { name: 'Add to calendar' });
		expect(link.getAttribute('href')).toBe('/x');
		expect(link.getAttribute('data-testid')).toBe('cta');
		expect(link.getAttribute('target')).toBe('_blank');
	});

	// The button branch already spread rest; the load-bearing assertion here
	// is the `type="button"` default — a Button inside a form must never
	// fall back to the native `submit`.
	it('defaults to type=button (and forwards rest) on the button variant', () => {
		render(ButtonHarness, { props: { 'aria-label': 'Save', 'data-testid': 'save' } });

		const button = screen.getByRole('button', { name: 'Save' });
		expect(button.getAttribute('type')).toBe('button');
		expect(button.getAttribute('data-testid')).toBe('save');
	});
});
