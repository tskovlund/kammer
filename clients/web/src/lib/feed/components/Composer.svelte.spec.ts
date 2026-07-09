import { afterEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, waitFor } from '@testing-library/svelte';
import Composer from './Composer.svelte';
import { t } from '$lib/i18n/i18n.svelte.js';
import type { FeedStore } from '$lib/feed/feed-store.svelte.js';
import type { Instance } from '$lib/instances/types.js';

function fakeStore(overrides: Partial<FeedStore> = {}): FeedStore {
	return {
		publish: vi.fn(async () => true),
		clearActionError: vi.fn(),
		...overrides
	} as unknown as FeedStore;
}

const instance = {
	id: 'i1',
	baseUrl: 'https://kammer.example.com',
	instanceName: 'Example',
	deviceToken: 'token-1',
	user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
	addedAt: '2026-01-01T00:00:00Z'
} as Instance;

const ref = { community: 'c', group: 'g' };

afterEach(() => {
	document.body.innerHTML = '';
});

describe('Composer focus handling (finding 4)', () => {
	it('returns focus to the text field after publishing, leaving it collapsed', async () => {
		const store = fakeStore();
		const { container } = render(Composer, { props: { store, instance, ref } });

		const textarea = container.querySelector('textarea')!;
		const form = container.querySelector('#post-composer')! as HTMLFormElement;

		// Expand the composer and type a post.
		await fireEvent.focus(textarea);
		expect(textarea.rows).toBe(4); // expanded
		await fireEvent.input(textarea, { target: { value: 'hello world' } });

		// Publishing focuses the submit button, which reset() then unmounts.
		const submit = container.querySelector('button[type="submit"]')! as HTMLButtonElement;
		submit.focus();
		expect(document.activeElement).toBe(submit);

		await fireEvent.submit(form);

		await waitFor(() => {
			expect(store.publish).toHaveBeenCalledTimes(1);
			// Focus is back on the text field, not stranded on the removed button.
			expect(document.activeElement).toBe(textarea);
		});
		// And the field programmatically refocused without re-expanding.
		expect(textarea.rows).toBe(2);
	});

	it('returns focus to the text field on cancel', async () => {
		const store = fakeStore();
		const { container } = render(Composer, { props: { store, instance, ref } });
		const textarea = container.querySelector('textarea')!;

		await fireEvent.focus(textarea);
		await fireEvent.input(textarea, { target: { value: 'draft' } });

		const cancelLabel = t('common.cancel');
		const cancel = [...container.querySelectorAll('button')].find(
			(b) => b.textContent?.trim() === cancelLabel
		)!;
		cancel.focus();
		await fireEvent.click(cancel);

		await waitFor(() => {
			expect(document.activeElement).toBe(textarea);
			expect(textarea.value).toBe(''); // reset cleared the draft
		});
		expect(textarea.rows).toBe(2);
	});
});
