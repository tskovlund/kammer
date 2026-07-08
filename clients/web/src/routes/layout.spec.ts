import { describe, expect, it } from 'vitest';
import { ssr } from './+layout';

describe('root layout', () => {
	it('disables SSR — the client is a pure SPA holding sessions to remote instances (ADR 0001)', () => {
		expect(ssr).toBe(false);
	});
});
