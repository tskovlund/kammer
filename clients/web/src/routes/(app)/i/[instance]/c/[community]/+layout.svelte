<script lang="ts">
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { accentRefresh } from '$lib/ui/accent-refresh.svelte.js';
	import CommunityAccent from '$lib/ui/CommunityAccent.svelte';

	let { children } = $props();

	// Per-community accent re-tint (issue #321, SPEC §21) for the whole
	// authed community tree. This layout owns the tint and nothing else:
	// it resolves the community best-effort and hands `accent_color` to
	// the scoped wrapper. Pages keep loading their own data exactly as
	// before — a failed (or slow) resolve here just leaves the default
	// accent, never an error state or a blocked render.
	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let accentColor = $state<string | null>(null);

	// Non-reactive: `page.params` is replaced wholesale on every navigation,
	// so the effect below re-fires even when instance and community are
	// unchanged; this key limits the reset + refetch to genuine changes.
	// The refresh version re-keys after the settings page saves a new
	// accent — the one same-community event that must re-resolve.
	let lastKey: string | null = null;
	// Monotonic run token: only the latest issued fetch may apply.
	let run = 0;

	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		const version = accentRefresh.version;
		const key = inst && communitySlug ? `${inst.id}:${communitySlug}:${version}` : null;
		if (key === lastKey) return;
		lastKey = key;
		// Reset on a community/instance change so the previous community's
		// tint never lingers over the next one's pages.
		accentColor = null;
		if (!inst || !communitySlug) return;

		const token = ++run;
		fetchCommunity(inst, communitySlug)
			.then((community) => {
				if (token === run) accentColor = community.accent_color;
			})
			.catch(() => {
				// Best-effort by design: the page's own load surfaces errors.
				// Re-arm the guard so the next navigation retries instead of
				// pinning the default accent for the whole visit.
				if (token === run) lastKey = null;
			});
	});
</script>

<CommunityAccent {accentColor}>
	{@render children()}
</CommunityAccent>
