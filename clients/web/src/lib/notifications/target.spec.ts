import { describe, expect, it } from 'vitest';
import type { Notification } from '$lib/feed/types.js';
import { notificationTarget } from './target.js';

function fixture(overrides: Partial<Notification> = {}): Notification {
	return {
		id: 'n1',
		kind: 'mention',
		actor: { id: 'actor', display_name: 'Alice', type: 'user' },
		post_id: 'p1',
		comment_id: null,
		event_id: null,
		community: {
			id: 'c1',
			slug: 'tagekammeret',
			name: 'TÅGEKAMMERET',
			description: null,
			accent_color: '#3E6B48',
			default_locale: 'en',
			listed_on_instance: false,
			require_real_names: false,
			viewer_can: []
		},
		group: { id: 'g1', name: 'Friday bar', slug: 'friday-bar' },
		inserted_at: '2026-06-01T10:00:00Z',
		read: false,
		read_at: null,
		...overrides
	};
}

describe('notificationTarget', () => {
	it('routes post/comment notifications to the instance-scoped group feed', () => {
		expect(notificationTarget(fixture(), 'instance-1')).toBe(
			'/i/instance-1/c/tagekammeret/g/friday-bar'
		);
	});

	it('routes event notifications to the event, taking precedence over the group', () => {
		expect(notificationTarget(fixture({ event_id: 'ev-1' }), 'instance-1')).toBe(
			'/i/instance-1/c/tagekammeret/e/ev-1'
		);
	});

	it('returns null when the payload carries no navigable target', () => {
		expect(notificationTarget(fixture({ community: undefined }), 'instance-1')).toBeNull();
		expect(notificationTarget(fixture({ group: null }), 'instance-1')).toBeNull();
	});
});
