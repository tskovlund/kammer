<script lang="ts">
	interface Props {
		class?: string;
	}

	let { class: className = '' }: Props = $props();
</script>

<!-- Calm loading placeholder — a slow opacity pulse rather than a spinner;
     prefers-reduced-motion collapses the animation globally (layout.css). -->
<div
	class="animate-[kammer-skeleton_2s_ease-in-out_infinite] rounded-lg bg-ink/10 {className}"
	aria-hidden="true"
></div>
