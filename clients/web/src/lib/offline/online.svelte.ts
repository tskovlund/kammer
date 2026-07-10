function hasWindow(): boolean {
	return typeof window !== 'undefined';
}

let value = $state(hasWindow() ? navigator.onLine : true);

if (hasWindow()) {
	window.addEventListener('online', () => {
		value = true;
	});
	window.addEventListener('offline', () => {
		value = false;
	});
}

/**
 * Reactive `navigator.onLine` mirror — a coarse, best-effort signal (it
 * reflects network-interface state, not "can actually reach any added
 * instance"), used to word the stale-data banner ("you're offline" vs.
 * "couldn't reach your accounts") rather than to gate any behaviour.
 */
export const online = {
	get value(): boolean {
		return value;
	}
};
