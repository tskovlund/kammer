<script lang="ts">
	import Button from '../Button.svelte';

	// Spreads whatever the spec passes onto Button, so it can exercise the
	// href (anchor) vs default (button) branches and arbitrary rest props.
	let props = $props();
</script>

<Button {...props}>Go</Button>
