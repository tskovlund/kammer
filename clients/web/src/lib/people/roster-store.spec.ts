import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { CustomField, Member, Roster } from './types.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return {
		...actual,
		fetchRoster: vi.fn(),
		updateMemberRole: vi.fn(),
		removeMember: vi.fn()
	};
});

import * as api from './api.js';
import { createRosterStore } from './roster-store.svelte.js';

// The mock spreads the actual module, so this stays the real function.
const { rosterFilterQuery } = api;

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

function member(id: string, role: Member['role'] = 'member'): Member {
	return {
		user: { id, display_name: id, bio: null, pronouns: null },
		role,
		joined_at: '2026-01-01T00:00:00Z',
		contact: {},
		custom_field_values: {}
	};
}

function field(id: string, field_type: CustomField['field_type']): CustomField {
	return {
		id,
		label: id,
		field_type,
		options: field_type === 'single_select' ? ['Horn', 'Bas'] : [],
		required: false,
		visibility: 'members',
		position: 0
	};
}

function roster(members: Member[], fields: CustomField[] = []): Roster {
	return { members, fields };
}

beforeEach(() => {
	vi.clearAllMocks();
});

describe('createRosterStore', () => {
	it('loads and exposes only single-select fields as filterable', async () => {
		vi.mocked(api.fetchRoster).mockResolvedValue(
			roster([member('a')], [field('f-text', 'text'), field('f-select', 'single_select')])
		);

		const store = createRosterStore(instance(), 'band');
		await store.load();

		expect(store.loadState).toBe('ready');
		expect(store.members).toHaveLength(1);
		expect(store.filterableFields.map((f) => f.id)).toEqual(['f-select']);
	});

	it('setFilter refetches with the filter; clearing a value drops its key', async () => {
		vi.mocked(api.fetchRoster).mockResolvedValue(roster([member('a')]));
		const store = createRosterStore(instance(), 'band');

		await store.setFilter('f1', 'Bas');
		expect(vi.mocked(api.fetchRoster)).toHaveBeenLastCalledWith(expect.anything(), 'band', {
			f1: 'Bas'
		});

		await store.setFilter('f1', '');
		expect(vi.mocked(api.fetchRoster)).toHaveBeenLastCalledWith(expect.anything(), 'band', {});
	});

	it('changeRole calls the API and refetches; a refusal lands in actionError', async () => {
		vi.mocked(api.fetchRoster).mockResolvedValue(roster([member('a', 'admin')]));
		vi.mocked(api.updateMemberRole).mockResolvedValue();
		const store = createRosterStore(instance(), 'band');

		await store.changeRole(member('a'), 'admin');
		expect(vi.mocked(api.updateMemberRole)).toHaveBeenCalledWith(
			expect.anything(),
			'band',
			'a',
			'admin'
		);
		expect(vi.mocked(api.fetchRoster)).toHaveBeenCalled();
		expect(store.actionError).toBeNull();

		vi.mocked(api.updateMemberRole).mockRejectedValue(new FeedApiError('forbidden', 'Nej.', 403));
		await store.changeRole(member('a'), 'member');
		expect(store.actionError?.kind).toBe('forbidden');
	});

	it('a stale filter response never overwrites a newer one', async () => {
		let resolveSlow!: (value: Roster) => void;
		const slow = new Promise<Roster>((resolve) => {
			resolveSlow = resolve;
		});
		vi.mocked(api.fetchRoster).mockReturnValueOnce(slow);
		vi.mocked(api.fetchRoster).mockResolvedValueOnce(roster([member('filtered')]));

		const store = createRosterStore(instance(), 'band');
		const first = store.load();
		await store.setFilter('f1', 'Bas');
		resolveSlow(roster([member('stale-full-list')]));
		await first;

		expect(store.members.map((m) => m.user.id)).toEqual(['filtered']);
	});
});

describe('rosterFilterQuery', () => {
	it('flattens to filter[<id>] pairs, drops blanks, and vanishes when empty', () => {
		expect(rosterFilterQuery({ f1: 'Bas', f2: '' })).toEqual({ 'filter[f1]': 'Bas' });
		expect(rosterFilterQuery({})).toBeUndefined();
		expect(rosterFilterQuery({ f2: '' })).toBeUndefined();
	});
});
