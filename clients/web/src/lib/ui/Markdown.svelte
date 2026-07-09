<script lang="ts">
	import { renderInlineMarkdown, renderMarkdown } from '$lib/feed/markdown.js';

	interface Props {
		source: string | null | undefined;
		/** Inline mode drops the wrapping paragraphs — used for comment bodies. */
		inline?: boolean;
		class?: string;
	}

	let { source, inline = false, class: className = '' }: Props = $props();

	// renderMarkdown/renderInlineMarkdown produce sanitized HTML (markdown-it
	// with html:false — no raw tags, dangerous URL schemes stripped), so this
	// is the one intentional, audited {@html} sink in the app.
	const html = $derived(inline ? renderInlineMarkdown(source) : renderMarkdown(source));
</script>

<div class="kammer-prose {className}">
	<!-- eslint-disable-next-line svelte/no-at-html-tags -->
	{@html html}
</div>

<style>
	/* Quiet, readable typography for user content — restrained, book-like
	   (SPEC §21). Scoped so it never leaks into the rest of the UI. */
	.kammer-prose {
		line-height: 1.65;
		word-break: break-word;
		overflow-wrap: anywhere;
	}
	.kammer-prose :global(p) {
		margin: 0 0 0.75em;
	}
	.kammer-prose :global(p:last-child) {
		margin-bottom: 0;
	}
	.kammer-prose :global(a) {
		color: var(--accent);
		text-decoration: underline;
		text-underline-offset: 2px;
	}
	.kammer-prose :global(ul),
	.kammer-prose :global(ol) {
		margin: 0 0 0.75em;
		padding-left: 1.4em;
	}
	.kammer-prose :global(ul) {
		list-style: disc;
	}
	.kammer-prose :global(ol) {
		list-style: decimal;
	}
	.kammer-prose :global(li) {
		margin: 0.15em 0;
	}
	.kammer-prose :global(blockquote) {
		margin: 0 0 0.75em;
		padding-left: 0.9em;
		border-left: 2px solid var(--line);
		color: var(--ink-muted);
	}
	.kammer-prose :global(code) {
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 0.9em;
		background: var(--paper);
		padding: 0.1em 0.35em;
		border-radius: 0.3rem;
	}
	.kammer-prose :global(pre) {
		margin: 0 0 0.75em;
		padding: 0.8em 1em;
		background: var(--paper);
		border: 1px solid var(--line);
		border-radius: 0.6rem;
		overflow-x: auto;
	}
	.kammer-prose :global(pre code) {
		background: none;
		padding: 0;
	}
	.kammer-prose :global(h1),
	.kammer-prose :global(h2),
	.kammer-prose :global(h3) {
		font-weight: 600;
		line-height: 1.3;
		margin: 0 0 0.5em;
	}
	.kammer-prose :global(h1) {
		font-size: 1.25em;
	}
	.kammer-prose :global(h2) {
		font-size: 1.15em;
	}
	.kammer-prose :global(h3) {
		font-size: 1.05em;
	}
</style>
