import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { flushSync } from 'svelte';
import { ApiError } from '$lib/api/errors.js';

const page = vi.hoisted(() => ({ params: { token: 'tok-1' } }));
vi.mock('$app/state', () => ({ page }));

const confirmStepUp = vi.hoisted(() => vi.fn());
vi.mock('$lib/instances/stepup.js', () => ({ confirmStepUp }));

import StepUpConfirmPage from './+page.svelte';

afterEach(() => {
	vi.clearAllMocks();
	document.body.innerHTML = '';
});

describe('step-up confirmation landing', () => {
	// The load-bearing defense (ADR 0029): the emailed link must NOT
	// confirm on open — a link-following mail scanner or a reflexively
	// opened forward would otherwise complete a step-up an attacker
	// requested on a stolen device token. Only the explicit click may
	// fire the confirm.
	it('never confirms on mount — only the explicit button click does', async () => {
		render(StepUpConfirmPage);
		flushSync();
		expect(confirmStepUp).not.toHaveBeenCalled();

		confirmStepUp.mockResolvedValueOnce(undefined);
		screen.getByRole('button', { name: "Yes, it's me" }).click();
		await vi.waitFor(() => expect(confirmStepUp).toHaveBeenCalledTimes(1));
		expect(confirmStepUp).toHaveBeenCalledWith(window.location.origin, 'tok-1');
	});

	it('a dead token reads as invalid; a transient failure offers retry', async () => {
		confirmStepUp.mockRejectedValueOnce(new ApiError('not_found', 'Not found.', 404));
		render(StepUpConfirmPage);
		screen.getByRole('button', { name: "Yes, it's me" }).click();
		await vi.waitFor(() => expect(screen.getByText("That link didn't work")).toBeTruthy());

		document.body.innerHTML = '';
		confirmStepUp.mockRejectedValueOnce(new ApiError('network', 'offline', null));
		render(StepUpConfirmPage);
		screen.getByRole('button', { name: "Yes, it's me" }).click();
		await vi.waitFor(() => expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy());
	});
});
