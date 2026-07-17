import type { Action } from 'svelte/action';

export interface DismissableOptions {
	/** Called when the popover should close (Escape or an outside click). */
	onDismiss: () => void;
	/**
	 * The control that opened the popover. Focus returns here when the popover
	 * closes, and clicks on it are ignored (the trigger owns its own toggle, so
	 * an outside-click dismiss here would fight it).
	 */
	trigger?: HTMLElement | null;
	/**
	 * Enable roving Arrow/Home/End navigation between the focusable items — for
	 * `role="menu"` popovers. Left off, only focus containment + dismissal apply.
	 */
	arrowKeys?: boolean;
}

/**
 * The one focusable-elements selector shared by every overlay: initial
 * focus here and the Tab trap in `StepUpModal` must agree on what counts
 * as focusable, or Tab can escape past an element focus landed on.
 */
export const FOCUSABLE =
	'[role="menuitem"], button:not([disabled]), [href], input:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * Popover behaviour shared by the reaction picker and the post menu: on open it
 * moves focus into the popover; while open, Escape and outside clicks dismiss it
 * and (optionally) arrow keys move between items; on close it restores focus to
 * the trigger. Because the popovers are conditionally rendered, the action's
 * mount/destroy line up with open/close, so this needs no `open` flag of its own.
 */
export const dismissable: Action<HTMLElement, DismissableOptions> = (node, options) => {
	let current = options;

	function items(): HTMLElement[] {
		return Array.from(node.querySelectorAll<HTMLElement>(FOCUSABLE));
	}

	function onKeydown(event: KeyboardEvent): void {
		if (event.key === 'Escape') {
			event.preventDefault();
			current.onDismiss();
			current.trigger?.focus();
			return;
		}
		if (!current.arrowKeys) return;

		const focusable = items();
		if (focusable.length === 0) return;
		const index = focusable.indexOf(document.activeElement as HTMLElement);

		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			const delta = event.key === 'ArrowDown' ? 1 : -1;
			const next = (index + delta + focusable.length) % focusable.length;
			focusable[next].focus();
		} else if (event.key === 'Home') {
			event.preventDefault();
			focusable[0].focus();
		} else if (event.key === 'End') {
			event.preventDefault();
			focusable[focusable.length - 1].focus();
		}
	}

	function onPointerDown(event: Event): void {
		const target = event.target as Node | null;
		if (!target) return;
		if (node.contains(target)) return;
		if (current.trigger?.contains(target)) return;
		current.onDismiss();
	}

	// Move focus into the popover on open (first item, else the container).
	const first = items()[0];
	(first ?? node).focus();

	document.addEventListener('keydown', onKeydown, true);
	document.addEventListener('pointerdown', onPointerDown, true);

	return {
		update(next: DismissableOptions) {
			current = next;
		},
		destroy() {
			document.removeEventListener('keydown', onKeydown, true);
			document.removeEventListener('pointerdown', onPointerDown, true);
			// Restore focus to the trigger only if focus is still inside the closing
			// popover (or was lost to the body) — never yank it from wherever the
			// user has since clicked.
			const active = document.activeElement;
			if (!active || active === document.body || node.contains(active)) {
				current.trigger?.focus();
			}
		}
	};
};
