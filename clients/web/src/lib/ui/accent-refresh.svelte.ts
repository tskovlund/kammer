/**
 * Cache-buster for the community accent. The community layouts resolve
 * `accent_color` once per community and deliberately skip refetching on
 * intra-community navigation — so a page that changes the accent (community
 * settings) must tell them their resolve is stale. Bumping the version
 * re-keys the layouts' navigation guard, triggering one re-resolve.
 */
export const accentRefresh = $state({ version: 0 });

export function refreshCommunityAccent(): void {
	accentRefresh.version += 1;
}
