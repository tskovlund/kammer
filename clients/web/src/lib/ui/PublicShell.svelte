<script lang="ts">
	import type { Snippet } from 'svelte';
	import { t } from '$lib/i18n/i18n.svelte.js';

	interface Props {
		/** Tailwind max-width class for the content column. */
		maxWidth?: string;
		children: Snippet;
	}

	let { maxWidth = 'max-w-sm', children }: Props = $props();
</script>

<!-- Unauthenticated shell for tokenless guest/newsletter/legal/setup screens
     (issue #185) — same calm centered-column chrome as `/sign-in`, kept as
     its own component rather than reusing `sign-in/+layout.svelte` since
     that layout is scoped to the sign-in route group and carries a
     sign-in-specific tagline. -->
<div class="flex min-h-dvh flex-col items-center px-4 pt-[max(4rem,12vh)] pb-16">
	<header class="text-center">
		<p class="text-2xl font-semibold tracking-tight text-ink">{t('app.name')}</p>
	</header>
	<main class="mt-10 w-full {maxWidth}">
		{@render children()}
	</main>
</div>
