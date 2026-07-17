import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';

const page = vi.hoisted(() => ({ status: 404, error: { message: 'raw-server-detail' } }));
vi.mock('$app/state', () => ({ page }));

import ErrorPage from './+error.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

// The branded floor under every unrenderable route (part of #270). The two
// cases are the two copy branches; both must always offer a way home, since
// this page can render with no signed-in instance and no layout data.
describe('root error page', () => {
	it('renders not-found copy and a link home for a stale or mistyped URL', () => {
		page.status = 404;
		render(ErrorPage);

		expect(screen.getByText('Page not found')).toBeTruthy();
		// `resolve()` may prefix a base path — pin the route, not the prefix.
		expect(document.querySelector('#error-home')?.getAttribute('href')).toMatch(/\/$/);
	});

	it('renders generic copy for any other failure status', () => {
		page.status = 500;
		render(ErrorPage);

		expect(screen.getByText('Something went wrong')).toBeTruthy();
		expect(document.querySelector('#error-home')).toBeTruthy();
	});

	it('never renders the raw error detail — copy comes from the status alone', () => {
		page.status = 500;
		render(ErrorPage);

		// The mocked page.error.message above is a canary: if a future edit
		// interpolates it, this regresses loudly.
		expect(screen.queryByText('raw-server-detail')).toBeNull();
	});
});
