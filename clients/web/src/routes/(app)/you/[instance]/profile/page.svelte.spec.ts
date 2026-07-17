import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';
import type { Profile } from '$lib/people/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$app/state', () => ({ page: { params: { instance: 'i1' } } }));
vi.mock('$app/paths', () => ({ resolve: (path: string) => path }));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});
// The header renders regardless of the profile load. The multi test lets
// the fetch fail fast (it only asserts the header); the solo test resolves
// it so the body's solo copy renders too.
vi.mock('$lib/people/api.js', () => ({
	fetchProfile: vi.fn(async () => {
		throw new Error('unreachable in this spec');
	}),
	profileParamsErrorKeys: vi.fn(),
	requestEmailChange: vi.fn(),
	updateProfile: vi.fn()
}));
vi.mock('$lib/events/api.js', () => ({ fetchCommunities: vi.fn(async () => []) }));

import Page from './+page.svelte';
import { fetchProfile } from '$lib/people/api.js';

const profileFixture: Profile = {
	id: 'p1',
	display_name: 'Alice',
	email: 'a@example.com',
	locale: 'en',
	timezone: 'Europe/Copenhagen',
	digest_frequency: 'off',
	feed_sort: 'chronological',
	contact_phone_visibility: 'hidden',
	contact_email_visibility: 'hidden',
	contact_note_visibility: 'hidden'
};

beforeEach(() => {
	mocks.list = [testInstance('i1', 'Example Club')];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('profile page — single-account collapse (#322)', () => {
	it('drops the instance name and uses the solo settings copy when it is the only account', async () => {
		vi.mocked(fetchProfile).mockResolvedValueOnce(profileFixture);
		render(Page);

		await waitFor(() =>
			expect(
				screen.getByText(
					'Emails about your account — sign-in links, notifications, and digests — use these settings.'
				)
			).toBeTruthy()
		);
		expect(screen.getByText('How you appear to other members.')).toBeTruthy();
		expect(screen.queryByText(/Example Club/)).toBeNull();
	});

	it('names the instance when several accounts are added', () => {
		mocks.list = [testInstance('i1', 'Example Club'), testInstance('i2', 'Second Club')];
		render(Page);

		expect(screen.getByText('How you appear to other members on Example Club.')).toBeTruthy();
	});
});
