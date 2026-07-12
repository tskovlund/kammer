import { afterEach, describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';

import AttendanceMatrix from './AttendanceMatrix.svelte';
import type { EventSeriesDetail } from '../types.js';

afterEach(() => {
	document.body.innerHTML = '';
});

type Attendance = EventSeriesDetail['attendance'];

describe('AttendanceMatrix', () => {
	it('renders a member row and the RSVP glyphs labelled by status', () => {
		const attendance: Attendance = {
			occurrences: [
				{ id: 'o1', starts_at: '2026-06-10T10:00:00Z' },
				{ id: 'o2', starts_at: '2026-06-17T10:00:00Z' }
			],
			rows: [{ member: { id: 'u1', display_name: 'Alice' }, statuses: ['yes', null] }]
		};

		render(AttendanceMatrix, { props: { attendance } });

		// The member is a row header, and each column carries its RSVP as the
		// cell's accessible label (the glyph itself is decorative).
		expect(screen.getByRole('rowheader', { name: 'Alice' })).toBeTruthy();
		expect(screen.getByLabelText('Going')).toBeTruthy();
		expect(screen.getByLabelText('No answer')).toBeTruthy();
	});

	it('shows an empty state when there are no upcoming occurrences to track', () => {
		const attendance: Attendance = { occurrences: [], rows: [] };

		render(AttendanceMatrix, { props: { attendance } });

		expect(screen.getByText(/no upcoming dates/i)).toBeTruthy();
		expect(screen.queryByRole('table')).toBeNull();
	});
});
