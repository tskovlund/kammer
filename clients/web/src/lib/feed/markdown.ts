import MarkdownIt from 'markdown-it';

/**
 * The feed renders Markdown the server stores verbatim (`*_markdown`
 * fields — the serializer never renders it), so the client must render it
 * *safely*: a post body is untrusted user input.
 *
 * The safety model is "no raw HTML, ever", enforced at the parser rather
 * than bolted on afterwards. `markdown-it` with `html: false` (its default)
 * escapes every raw HTML tag in the source — a `<script>` in a post body
 * becomes the text `&lt;script&gt;`, never a live element — and its built-in
 * `validateLink` rejects `javascript:`, `vbscript:`, and `file:` URLs, plus
 * every `data:` URL except the non-scriptable image subset
 * (`data:image/gif|png|jpeg|webp`). The generated tag set is a fixed, safe
 * Markdown vocabulary
 * (paragraphs, emphasis, lists, blockquotes, code, headings, links), so the
 * output is safe to hand to Svelte's `{@html}`. This runs in pure JS with no
 * DOM dependency, which keeps the sanitization guarantee unit-testable in a
 * node environment (no jsdom).
 *
 * Images in the body are deliberately downgraded to links: attachments are
 * the intended, first-class image channel (thumbnailed, authorized), and
 * silently loading an arbitrary remote `![](url)` would be a tracking-pixel
 * and layout-jank vector for no real authoring benefit.
 */
const md = new MarkdownIt({
	html: false,
	linkify: true,
	breaks: true,
	typographer: false
});

// Links open in a new tab and never leak the referrer or grant window access
// to the opened page.
const defaultLinkOpen =
	md.renderer.rules.link_open ??
	((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));

md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
	const token = tokens[idx];
	token.attrSet('target', '_blank');
	token.attrSet('rel', 'noopener noreferrer nofollow ugc');
	return defaultLinkOpen(tokens, idx, options, env, self);
};

// Render `![alt](url)` as a plain link to the URL rather than an inline
// remote image (see the module comment). `validateLink` has already run, so
// any dangerous scheme has been stripped to an empty href.
md.renderer.rules.image = (tokens, idx) => {
	const token = tokens[idx];
	const src = token.attrGet('src') ?? '';
	const alt = token.content || src;
	if (!src) return md.utils.escapeHtml(alt);
	const safeSrc = md.utils.escapeHtml(src);
	const safeAlt = md.utils.escapeHtml(alt);
	return `<a href="${safeSrc}" target="_blank" rel="noopener noreferrer nofollow ugc">${safeAlt}</a>`;
};

/** Render trusted-shape Markdown to sanitized HTML for `{@html}`. */
export function renderMarkdown(source: string | null | undefined): string {
	if (!source) return '';
	return md.render(source).trim();
}

/** Render inline Markdown (no wrapping `<p>`) — for comment bodies. */
export function renderInlineMarkdown(source: string | null | undefined): string {
	if (!source) return '';
	return md.renderInline(source).trim();
}
