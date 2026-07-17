import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import CommunityAccent from './CommunityAccent.svelte';
import { deriveAccentTokens } from './accent.js';

const children = createRawSnippet(() => ({ render: () => '<p>page content</p>' }));

describe('CommunityAccent', () => {
	it('scopes the derived palettes to its subtree via the data attribute', () => {
		const { container } = render(CommunityAccent, {
			props: { accentColor: '#3e6b48', children }
		});

		const wrapper = container.querySelector('[data-community-accent]');
		expect(wrapper).not.toBeNull();
		const style = wrapper!.getAttribute('style')!;
		const tokens = deriveAccentTokens('#3e6b48')!;
		expect(style).toContain(`--community-accent-light: ${tokens.light.accent}`);
		expect(style).toContain(`--community-accent-dark: ${tokens.dark.accent}`);
		expect(screen.getByText('page content')).toBeTruthy();
	});

	it('applies no override without a resolvable accent — the default tokens stand', () => {
		const { container } = render(CommunityAccent, {
			props: { accentColor: null, children }
		});

		// No attribute means the layout.css bridge never engages: this is
		// the zero-regression path every non-community surface shares.
		expect(container.querySelector('[data-community-accent]')).toBeNull();
		expect(screen.getByText('page content')).toBeTruthy();
	});
});
