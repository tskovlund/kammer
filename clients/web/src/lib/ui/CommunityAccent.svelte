<script lang="ts">
	import type { Snippet } from 'svelte';
	import { communityAccentStyle, deriveAccentTokens } from './accent.js';

	interface Props {
		/**
		 * The community's stored `accent_color` — `null` while unknown
		 * (loading, load failed, no community context), which renders the
		 * default accent untouched.
		 */
		accentColor: string | null;
		children: Snippet;
	}

	let { accentColor, children }: Props = $props();

	const tokens = $derived(deriveAccentTokens(accentColor));
</script>

<!-- Per-community accent re-tint (issue #321, SPEC §21): a display:contents
     wrapper — layout-neutral, but a real element for the CSS custom-property
     cascade — that scopes the derived accent to this subtree. The wrapper is
     always rendered so children never remount when the accent resolves; only
     the attribute + inline palettes toggle. The [data-community-accent]
     rules in routes/layout.css pick the palette per theme, and unmounting
     the wrapper is the cleanup — the override cannot outlive the surface or
     leak onto merged/cross-community screens. -->
<div
	class="contents"
	data-community-accent={tokens ? '' : undefined}
	style={tokens ? communityAccentStyle(tokens) : undefined}
>
	{@render children()}
</div>
