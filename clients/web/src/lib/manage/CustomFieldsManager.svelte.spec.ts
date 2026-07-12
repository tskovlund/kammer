import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/svelte';
import type { Instance } from '$lib/instances/types.js';

vi.mock('$lib/manage/api.js', async (importActual) => {
	const actual = await importActual<typeof import('$lib/manage/api.js')>();
	return {
		...actual,
		fetchCustomFields: vi.fn(),
		createCustomField: vi.fn(),
		updateCustomField: vi.fn(),
		deleteCustomField: vi.fn()
	};
});

import * as api from '$lib/manage/api.js';
import { ManageApiError, type CustomField } from '$lib/manage/api.js';
import CustomFieldsManager from './CustomFieldsManager.svelte';

function instance(): Instance {
	return {
		id: 'i',
		baseUrl: 'https://i.example',
		instanceName: 'I',
		deviceToken: 't',
		user: { id: 'u', email: 'a@a', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function field(overrides: Partial<CustomField> = {}): CustomField {
	return {
		id: 'f1',
		label: 'Instrument',
		field_type: 'text',
		options: [],
		required: false,
		visibility: 'members',
		position: 0,
		...overrides
	};
}

function renderManager() {
	return render(CustomFieldsManager, { instance: instance(), communitySlug: 'band' });
}

beforeEach(() => {
	vi.mocked(api.fetchCustomFields).mockReset().mockResolvedValue([]);
	vi.mocked(api.createCustomField).mockReset();
	vi.mocked(api.updateCustomField).mockReset();
	vi.mocked(api.deleteCustomField).mockReset();
});

describe('CustomFieldsManager', () => {
	it('lists the existing fields', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([
			field({ id: 'f1', label: 'Instrument', field_type: 'text' }),
			field({ id: 'f2', label: 'Section', field_type: 'single_select', options: ['Sopran'] })
		]);

		renderManager();

		await waitFor(() => expect(screen.getByText('Instrument')).toBeTruthy());
		expect(screen.getByText('Section')).toBeTruthy();
	});

	it('adds a field, sending the composed params and appending the result', async () => {
		vi.mocked(api.createCustomField).mockResolvedValue(
			field({ id: 'new', label: 'Dietary needs' })
		);

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-fields-add-form')).toBeTruthy());

		await fireEvent.input(document.querySelector('#custom-field-label')!, {
			target: { value: 'Dietary needs' }
		});
		await fireEvent.submit(document.querySelector('#custom-fields-add-form')!);

		await waitFor(() =>
			expect(api.createCustomField).toHaveBeenCalledWith(expect.anything(), 'band', {
				label: 'Dietary needs',
				field_type: 'text',
				visibility: 'members',
				required: false,
				options: []
			})
		);
		expect(await screen.findByText('Dietary needs')).toBeTruthy();
	});

	it('maps a 422 options error to its own copy, not the server string', async () => {
		vi.mocked(api.createCustomField).mockRejectedValue(
			new ManageApiError('validation', 'Validation failed.', 422, { options: ["can't be blank"] })
		);

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-type')).toBeTruthy());

		// Switch to single_select so the options field renders, then submit.
		await fireEvent.change(document.querySelector('#custom-field-type')!, {
			target: { value: 'single_select' }
		});
		await fireEvent.input(document.querySelector('#custom-field-label')!, {
			target: { value: 'Section' }
		});
		await fireEvent.submit(document.querySelector('#custom-fields-add-form')!);

		expect(await screen.findByText('Add at least one choice.')).toBeTruthy();
		// The English server string must never render (#253).
		expect(screen.queryByText("can't be blank")).toBeNull();
	});

	it('toggles a field required with the flipped value', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([field({ id: 'f1', required: false })]);
		vi.mocked(api.updateCustomField).mockResolvedValue(field({ id: 'f1', required: true }));

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-required-f1')).toBeTruthy());

		await fireEvent.click(document.querySelector('#custom-field-required-f1')!);

		expect(api.updateCustomField).toHaveBeenCalledWith(expect.anything(), 'band', 'f1', {
			required: true
		});
	});

	it('reverts the required checkbox when the server rejects the toggle', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([field({ id: 'f1', required: false })]);
		vi.mocked(api.updateCustomField).mockRejectedValue(new ManageApiError('server', 'nope', 500));

		renderManager();
		const checkbox = () => document.querySelector('#custom-field-required-f1') as HTMLInputElement;
		await waitFor(() => expect(checkbox()).toBeTruthy());
		expect(checkbox().checked).toBe(false);

		await fireEvent.click(checkbox());

		// The server refused, so the box must return to the still-not-required
		// server truth — a one-way `checked` binding won't undo the native
		// click on its own, and a checkbox lying about `required` misleads a
		// manager about who gets nagged (ADR 0020).
		await waitFor(() => expect(checkbox().checked).toBe(false));
		expect(api.updateCustomField).toHaveBeenCalledWith(expect.anything(), 'band', 'f1', {
			required: true
		});
		// The failure is surfaced on the row, not swallowed.
		expect(await screen.findByText("Couldn't save that change.")).toBeTruthy();
	});

	it('edits a field label and visibility, sending only what changed', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([
			field({ id: 'f1', label: 'Instrument', visibility: 'members' })
		]);
		vi.mocked(api.updateCustomField).mockResolvedValue(
			field({ id: 'f1', label: 'Main instrument', visibility: 'admins' })
		);

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-edit-f1')).toBeTruthy());

		await fireEvent.click(document.querySelector('#custom-field-edit-f1')!);
		await fireEvent.input(document.querySelector('#custom-field-edit-label-f1')!, {
			target: { value: 'Main instrument' }
		});
		await fireEvent.change(document.querySelector('#custom-field-edit-visibility-f1')!, {
			target: { value: 'admins' }
		});
		await fireEvent.submit(document.querySelector('#custom-field-edit-form-f1')!);

		await waitFor(() =>
			expect(api.updateCustomField).toHaveBeenCalledWith(expect.anything(), 'band', 'f1', {
				label: 'Main instrument',
				visibility: 'admins'
			})
		);
		// The row leaves edit mode showing the new label.
		expect(await screen.findByText('Main instrument')).toBeTruthy();
	});

	it('maps a 422 on edit to its own label copy, not the server string', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([field({ id: 'f1', label: 'Instrument' })]);
		vi.mocked(api.updateCustomField).mockRejectedValue(
			new ManageApiError('validation', 'Validation failed.', 422, { label: ["can't be blank"] })
		);

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-edit-f1')).toBeTruthy());

		await fireEvent.click(document.querySelector('#custom-field-edit-f1')!);
		await fireEvent.submit(document.querySelector('#custom-field-edit-form-f1')!);

		// The changeset's `label` detail maps to our own copy; the English
		// server string never renders (#253).
		expect(await screen.findByText('Enter a label.')).toBeTruthy();
		expect(screen.queryByText("can't be blank")).toBeNull();
	});

	it('surfaces a failed delete on the row instead of silently dropping it', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([field({ id: 'f1', label: 'Instrument' })]);
		vi.mocked(api.deleteCustomField).mockRejectedValue(new ManageApiError('server', 'nope', 500));

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-delete-f1')).toBeTruthy());

		await fireEvent.click(document.querySelector('#custom-field-delete-f1')!);
		await fireEvent.click(document.querySelector('#custom-field-confirm-delete-f1')!);

		// The row stays and the failure is announced — not swallowed.
		expect(await screen.findByText("Couldn't delete this field.")).toBeTruthy();
		expect(screen.getByText('Instrument')).toBeTruthy();
	});

	it('deletes a field only after a confirm step, then removes the row', async () => {
		vi.mocked(api.fetchCustomFields).mockResolvedValue([field({ id: 'f1', label: 'Instrument' })]);
		vi.mocked(api.deleteCustomField).mockResolvedValue(undefined);

		renderManager();
		await waitFor(() => expect(document.querySelector('#custom-field-delete-f1')).toBeTruthy());

		// First click only arms the confirm — nothing deleted yet.
		await fireEvent.click(document.querySelector('#custom-field-delete-f1')!);
		expect(api.deleteCustomField).not.toHaveBeenCalled();

		await fireEvent.click(document.querySelector('#custom-field-confirm-delete-f1')!);

		await waitFor(() =>
			expect(api.deleteCustomField).toHaveBeenCalledWith(expect.anything(), 'band', 'f1')
		);
		await waitFor(() => expect(screen.queryByText('Instrument')).toBeNull());
	});
});
