import { afterEach, describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';

import AttendanceMatrix from './AttendanceMatrix.svelte';
import type { EventSeriesDetail } from '../types.js';

afterEach(() => {
	document.body.innerHTML = '';
});

type Attendance = EventSeriesDetail['attendance'];

describe('AttendanceMatrix', () => {
	it('renders a member row, one column per occurrence, and every RSVP labelled by status', () => {
		const attendance: Attendance = {
			occurrences: [
				{ id: 'o1', starts_at: '2026-06-10T10:00:00Z' },
				{ id: 'o2', starts_at: '2026-06-17T10:00:00Z' },
				{ id: 'o3', starts_at: '2026-06-24T10:00:00Z' },
				{ id: 'o4', starts_at: '2026-07-01T10:00:00Z' },
				{ id: 'o5', starts_at: '2026-07-08T10:00:00Z' }
			],
			rows: [
				{
					member: { id: 'u1', display_name: 'Alice' },
					statuses: ['yes', 'maybe', 'no', 'waitlisted', null]
				}
			]
		};

		render(AttendanceMatrix, { props: { attendance } });

		// The member is a row header; the occurrences are column headers.
		expect(screen.getByRole('rowheader', { name: 'Alice' })).toBeTruthy();
		expect(screen.getAllByRole('columnheader')).toHaveLength(6); // Member + 5 dates

		// Every cell carries its RSVP as the accessible label (the glyph itself
		// is decorative) — the full status→label mapping, not just one branch.
		expect(screen.getByLabelText('Going')).toBeTruthy();
		expect(screen.getByLabelText('Maybe')).toBeTruthy();
		expect(screen.getByLabelText('Not going')).toBeTruthy();
		expect(screen.getByLabelText('Waitlisted')).toBeTruthy();
		expect(screen.getByLabelText('No answer')).toBeTruthy();
	});

	it('shows an empty state when there are no upcoming occurrences to track', () => {
		const attendance: Attendance = { occurrences: [], rows: [] };

		render(AttendanceMatrix, { props: { attendance } });

		expect(screen.getByText(/no upcoming dates/i)).toBeTruthy();
		expect(screen.queryByRole('table')).toBeNull();
	});
});
