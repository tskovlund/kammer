import { createSubscriber } from 'svelte/reactivity';

const MINUTE_MS = 60_000;

// One ticker shared by every relative timestamp on screen: createSubscriber
// starts the interval when the first subscribing effect appears and stops it
// when the last one is destroyed, so an idle app holds no timer and nothing
// leaks on unmount.
const subscribe = createSubscriber((update) => {
	const interval = setInterval(update, MINUTE_MS);
	return () => clearInterval(interval);
});

/**
 * The current time, reactive at minute granularity: reading it inside an
 * effect or `$derived` re-runs the caller once a minute while it stays
 * mounted — so a "2 min. ago" on a long-lived installed-PWA screen keeps
 * aging instead of fossilizing (part of #270). Outside a reactive context
 * it is just `new Date()`.
 */
export function minuteNow(): Date {
	subscribe();
	return new Date();
}
