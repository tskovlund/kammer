import { afterEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';
import type { ApiErrorKind } from '$lib/api/errors.js';
import en from '$lib/i18n/en.json';
import ErrorBanner from './ErrorBanner.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

describe('ErrorBanner', () => {
	// The component's whole purpose (#253/#270): the ApiErrorKind maps to
	// localized `errors.<kind>` copy — never the server's English message.
	// Several kinds prove the mapping is keyed by kind, not a constant.
	const kinds: ApiErrorKind[] = ['forbidden', 'network', 'server'];
	it.each(kinds)('renders the localized copy for kind "%s" in an alert', (kind) => {
		render(ErrorBanner, { props: { kind } });
		expect(screen.getByRole('alert').textContent).toContain(en[`errors.${kind}`]);
	});

	it('fires ondismiss when its dismiss button is clicked', async () => {
		const ondismiss = vi.fn();
		render(ErrorBanner, { props: { kind: 'server', ondismiss } });

		await fireEvent.click(screen.getByRole('button'));
		expect(ondismiss).toHaveBeenCalledOnce();
	});

	it('renders no dismiss button when ondismiss is omitted', () => {
		render(ErrorBanner, { props: { kind: 'server' } });
		expect(screen.queryByRole('button')).toBeNull();
	});
});
