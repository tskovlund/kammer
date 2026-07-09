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
	refresh(): void {
		list = instanceStore.list();
	}
};
