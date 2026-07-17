<script lang="ts">
	import { page } from '$app/state';
	import { fetchPublicCommunity } from '$lib/public/api.js';
	import CommunityAccent from '$lib/ui/CommunityAccent.svelte';

	let { children } = $props();

	// Per-community accent re-tint (issue #321, SPEC §21) for the public
	// community tree — the group/event/post pages only fetch their own
	// resource, so the community's `accent_color` is resolved here, once
	// per community, over the same tokenless read the landing page uses.
	// Best-effort: a community that isn't publicly readable (the neutral
	// 404, issue #156/#161) simply keeps the default accent while the
	// page below renders whatever it can.
	let accentColor = $state<string | null>(null);

	// Non-reactive: `page.params` is replaced wholesale on every navigation,
	// so the effect below re-fires even when the community is unchanged;
	// this guard limits the reset + refetch to genuine community changes.
	let lastSlug: string | null = null;
	// Monotonic run token: only the latest issued fetch may apply.
	let run = 0;

	$effect(() => {
		const communitySlug = page.params.community ?? null;
		if (communitySlug === lastSlug) return;
		lastSlug = communitySlug;
		accentColor = null;
		if (!communitySlug) return;

		const token = ++run;
		fetchPublicCommunity(window.location.origin, communitySlug)
			.then((data) => {
				if (token === run) accentColor = data.community.accent_color;
			})
			.catch(() => {
				// Best-effort by design: the page's own load surfaces errors.
				// Re-arm the guard so the next navigation retries instead of
				// pinning the default accent for the whole visit.
				if (token === run) lastSlug = null;
			});
	});
</script>

<CommunityAccent {accentColor}>
	{@render children()}
</CommunityAccent>
