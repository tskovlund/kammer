import { describe, expect, it } from 'vitest';
import { base } from '$app/paths';
import { joinedHref, type InviteAccept } from './api.js';

// joinedHref reads only community.slug, group?.slug, and
// missing_required_fields.length — the fixture carries exactly that.
function accepted(overrides: Record<string, unknown> = {}): InviteAccept {
	return {
		community: { slug: 'kammerkoret' },
		group: null,
		missing_required_fields: [],
		...overrides
	} as unknown as InviteAccept;
}

describe('joinedHref', () => {
	it('lands a group invite in that group’s feed', () => {
		expect(
			joinedHref('i1', accepted({ group: { id: 'g1', name: 'General', slug: 'general' } }))
		).toBe(`${base}/i/i1/c/kammerkoret/g/general`);
	});

	it('lands a community-wide invite on the Groups tab', () => {
		expect(joinedHref('i1', accepted())).toBe(`${base}/groups`);
	});

	it('detours through the profile page when required fields are unanswered', () => {
		expect(joinedHref('i1', accepted({ missing_required_fields: [{ id: 'f1' }] }))).toBe(
			`${base}/you/i1/profile`
		);
	});
});
