import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { dismissable } from './dismissable.js';

/**
 * The action is a plain `(node, options) => { update, destroy }` function, so we
 * exercise it against real jsdom nodes and real events — no component render
 * needed. `create` mimics Svelte mounting the popover when it opens; `destroy`
 * mimics unmounting it on close.
 */
function mount(options: Parameters<typeof dismissable>[1], itemCount = 2) {
	const trigger = document.createElement('button');
	trigger.textContent = 'open';
	document.body.appendChild(trigger);
	trigger.focus();

	const menu = document.createElement('div');
	menu.setAttribute('role', 'menu');
	menu.tabIndex = -1;
	for (let i = 0; i < itemCount; i++) {
		const item = document.createElement('button');
		item.setAttribute('role', 'menuitem');
		item.textContent = `item ${i}`;
		menu.appendChild(item);
	}
	document.body.appendChild(menu);

	const handle = dismissable(menu, { trigger, ...options });
	return { trigger, menu, items: [...menu.querySelectorAll('button')] as HTMLElement[], handle };
}

beforeEach(() => {
	document.body.innerHTML = '';
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('dismissable action', () => {
	it('moves focus into the popover on open (first item)', () => {
		const { items } = mount({ onDismiss: vi.fn() });
		expect(document.activeElement).toBe(items[0]);
	});

	it('focuses the container itself when there are no focusable items', () => {
		const { menu } = mount({ onDismiss: vi.fn() }, 0);
		expect(document.activeElement).toBe(menu);
	});

	it('dismisses and restores focus to the trigger on Escape', () => {
		const onDismiss = vi.fn();
		const { trigger, handle } = mount({ onDismiss });

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
		expect(onDismiss).toHaveBeenCalledTimes(1);
		expect(document.activeElement).toBe(trigger);

		// Svelte then unmounts the popover; focus must stay on the trigger.
		handle?.destroy?.();
		expect(document.activeElement).toBe(trigger);
	});

	it('dismisses on an outside click but not on clicks inside the popover', () => {
		const onDismiss = vi.fn();
		const { items } = mount({ onDismiss });

		items[0].dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }));
		expect(onDismiss).not.toHaveBeenCalled();

		const outside = document.createElement('div');
		document.body.appendChild(outside);
		outside.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }));
		expect(onDismiss).toHaveBeenCalledTimes(1);
	});

	it('ignores pointer events on the trigger (it owns its own toggle)', () => {
		const onDismiss = vi.fn();
		const { trigger } = mount({ onDismiss });
		trigger.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }));
		expect(onDismiss).not.toHaveBeenCalled();
	});

	it('roves focus with arrow keys, wrapping at the ends, when arrowKeys is set', () => {
		const { items } = mount({ onDismiss: vi.fn(), arrowKeys: true }, 3);
		expect(document.activeElement).toBe(items[0]);

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
		expect(document.activeElement).toBe(items[1]);

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }));
		expect(document.activeElement).toBe(items[2]);

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
		expect(document.activeElement).toBe(items[0]); // wraps forward

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }));
		expect(document.activeElement).toBe(items[2]); // wraps backward

		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
		expect(document.activeElement).toBe(items[0]);
	});

	it('leaves arrow keys alone when arrowKeys is not set', () => {
		const { items } = mount({ onDismiss: vi.fn() });
		expect(document.activeElement).toBe(items[0]);
		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
		expect(document.activeElement).toBe(items[0]);
	});

	it('restores focus to the trigger when unmounted while focus is inside', () => {
		const { trigger, handle } = mount({ onDismiss: vi.fn() });
		handle?.destroy?.();
		expect(document.activeElement).toBe(trigger);
	});

	it('does not steal focus back if the user has focused something else', () => {
		const { handle } = mount({ onDismiss: vi.fn() });
		const elsewhere = document.createElement('input');
		document.body.appendChild(elsewhere);
		elsewhere.focus();

		handle?.destroy?.();
		expect(document.activeElement).toBe(elsewhere);
	});

	it('stops handling events once destroyed', () => {
		const onDismiss = vi.fn();
		const { handle } = mount({ onDismiss });
		handle?.destroy?.();

		const outside = document.createElement('div');
		document.body.appendChild(outside);
		outside.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }));
		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
		expect(onDismiss).not.toHaveBeenCalled();
	});
});
