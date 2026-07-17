import { instanceStore } from './store.js';
import type { Instance } from './types.js';

let list = $state<Instance[]>(instanceStore.list());

/**
 * Reactive mirror of `instanceStore` for the UI layer (the store itself
 * stays framework-light for node-environment tests). Mutations go through
 * the api.ts flows (exchangeAndAddInstance / revokeAndRemoveInstance);
 * callers then `refresh()` to re-read persisted state.
 */
export const instances = {
	get list(): Instance[] {
		return list;
	},
	/**
	 * Exactly one instance added — the overwhelmingly common case (#322).
	 * Chrome consults this to drop the instance dimension: no provenance
	 * labels, no instance pickers, no "on <instance>" copy. Presentation
	 * only — routes keep their `[instance]` segment either way.
	 */
	get solo(): boolean {
		return list.length === 1;
	},
	/**
	 * More than one instance added. Not `!solo`: zero instances (signed
	 * out — the app layout redirects to onboarding) is neither solo nor
	 * several, so guards for "show the instance dimension" use this
	 * rather than negating `solo`.
	 */
	get several(): boolean {
		return list.length > 1;
	},
	refresh(): void {
		list = instanceStore.list();
	}
};
