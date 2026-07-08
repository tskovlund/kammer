// Kammer's Svelte client is a pure client-side SPA (ADR 0001): it holds
// sessions to N Kammer instances and merges views locally. There is no
// server to render against — every instance is a remote API the browser
// talks to directly.
export const ssr = false;
