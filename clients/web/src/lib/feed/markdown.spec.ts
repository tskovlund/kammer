import { describe, expect, it } from 'vitest';
import { renderInlineMarkdown, renderMarkdown } from './markdown';

describe('renderMarkdown sanitization', () => {
	it('escapes raw HTML tags instead of emitting live elements', () => {
		const html = renderMarkdown('Hello <script>alert(1)</script> world');
		expect(html).not.toContain('<script>');
		expect(html).toContain('&lt;script&gt;');
	});

	it('neutralizes an inline event-handler injection attempt', () => {
		// The raw tag is escaped to inert text — the substring "onerror" may
		// survive, but never as a live element/attribute, which is what matters.
		const html = renderMarkdown('<img src=x onerror="alert(1)">');
		expect(html).not.toContain('<img');
		expect(html).toContain('&lt;img');
	});

	it('never emits a link whose href is a javascript: URL', () => {
		const html = renderMarkdown('[click me](javascript:alert(document.cookie))');
		// markdown-it rejects the scheme, so no anchor is produced at all.
		expect(html).not.toContain('href="javascript:');
		expect(html).not.toContain('<a ');
	});

	it('never emits a link whose href is a data: URL', () => {
		const html = renderMarkdown('[x](data:text/html;base64,PHNjcmlwdD4=)');
		expect(html).not.toContain('href="data:text/html');
		expect(html).not.toContain('<a ');
	});

	it('downgrades body images to links so no remote image auto-loads', () => {
		const html = renderMarkdown('![tracker](https://evil.example/pixel.gif)');
		expect(html).not.toContain('<img');
		expect(html).toContain('href="https://evil.example/pixel.gif"');
	});

	it('does not render a javascript: image as any loadable resource', () => {
		const html = renderMarkdown('![x](javascript:alert(1))');
		expect(html).not.toContain('<img');
		expect(html).not.toContain('src="javascript:');
		expect(html).not.toContain('href="javascript:');
	});
});

describe('renderInlineMarkdown sanitization', () => {
	// Comment bodies are the second route into the app's single `{@html}` sink
	// (Markdown.svelte's inline mode), so the inline renderer needs the same
	// attack-class proof as the block renderer — same parser, but the guarantee
	// deserves assertions, not inference.
	it('escapes raw HTML so scripts and event-handler attributes never go live', () => {
		const script = renderInlineMarkdown('Hello <script>alert(1)</script> world');
		expect(script).not.toContain('<script>');
		expect(script).toContain('&lt;script&gt;');

		const handler = renderInlineMarkdown('<img src=x onerror="alert(1)">');
		expect(handler).not.toContain('<img');
		expect(handler).toContain('&lt;img');
	});

	it('never emits a link whose href is a javascript: or data: URL', () => {
		const js = renderInlineMarkdown('[click me](javascript:alert(document.cookie))');
		expect(js).not.toContain('href="javascript:');
		expect(js).not.toContain('<a ');

		const data = renderInlineMarkdown('[x](data:text/html;base64,PHNjcmlwdD4=)');
		expect(data).not.toContain('href="data:text/html');
		expect(data).not.toContain('<a ');
	});

	it('downgrades images to links and refuses a javascript: image entirely', () => {
		const remote = renderInlineMarkdown('![tracker](https://evil.example/pixel.gif)');
		expect(remote).not.toContain('<img');
		expect(remote).toContain('href="https://evil.example/pixel.gif"');

		const js = renderInlineMarkdown('![x](javascript:alert(1))');
		expect(js).not.toContain('<img');
		expect(js).not.toContain('src="javascript:');
		expect(js).not.toContain('href="javascript:');
	});

	it('emits no block elements — block syntax stays literal text', () => {
		expect(renderInlineMarkdown('# not a heading')).toBe('# not a heading');
		expect(renderInlineMarkdown('- not a list item')).toBe('- not a list item');
	});
});

describe('renderMarkdown formatting', () => {
	it('renders standard Markdown to the expected safe tag set', () => {
		expect(renderMarkdown('**bold** and _em_')).toBe(
			'<p><strong>bold</strong> and <em>em</em></p>'
		);
	});

	it('renders lists', () => {
		const html = renderMarkdown('- one\n- two');
		expect(html).toContain('<ul>');
		expect(html).toContain('<li>one</li>');
	});

	it('marks external links to open safely in a new tab', () => {
		const html = renderMarkdown('[Kammer](https://kammer.example.com)');
		expect(html).toContain('href="https://kammer.example.com"');
		expect(html).toContain('target="_blank"');
		expect(html).toContain('rel="noopener noreferrer nofollow ugc"');
	});

	it('autolinks bare URLs', () => {
		const html = renderMarkdown('see https://kammer.example.com for more');
		expect(html).toContain('<a href="https://kammer.example.com"');
	});

	it('returns an empty string for empty or nullish input', () => {
		expect(renderMarkdown('')).toBe('');
		expect(renderMarkdown(null)).toBe('');
		expect(renderMarkdown(undefined)).toBe('');
	});

	it('renders inline Markdown without a wrapping paragraph', () => {
		expect(renderInlineMarkdown('**hi**')).toBe('<strong>hi</strong>');
	});
});
