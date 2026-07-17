import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';

const afterNavigate = vi.hoisted(() => vi.fn());
vi.mock('$app/navigation', () => ({ afterNavigate }));

import BoundaryFallback from './BoundaryFallback.svelte';

afterEach(() => {
	vi.clearAllMocks();
	document.body.innerHTML = '';
});

describe('BoundaryFallback', () => {
	// The design point beyond the retry button: while the crash card is up,
	// a tripped boundary would otherwise survive navigation and keep
	// covering every route — so the card resets the boundary the moment the
	// user goes anywhere else.
	it('resets the boundary on navigation, not only via the retry button', async () => {
		const reset = vi.fn();
		render(BoundaryFallback, { props: { reset } });

		expect(afterNavigate).toHaveBeenCalledTimes(1);
		afterNavigate.mock.calls[0][0]();
		expect(reset).toHaveBeenCalledTimes(1);

		screen.getByRole('button', { name: 'Try again' }).click();
		expect(reset).toHaveBeenCalledTimes(2);
	});
});
