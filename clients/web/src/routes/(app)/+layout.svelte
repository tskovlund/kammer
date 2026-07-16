<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import TabIcon, { type TabIconName } from '$lib/ui/TabIcon.svelte';

	let { children } = $props();

	// Route guard: the shell is only for signed-in users — no added
	// instances means nothing to show, so hand over to the anonymous
	// landing (issue #260): ethos, the instance's community directory,
	// and a sign-in affordance — the same page the signed-out LiveView
	// root showed.
	$effect(() => {
		if (instances.list.length === 0) {
			void goto(resolve('/welcome'), { replaceState: true });
		}
	});

	const tabs: { href: string; icon: TabIconName; label: () => string }[] = [
		{ href: resolve('/'), icon: 'home', label: () => t('nav.home') },
		{ href: resolve('/events'), icon: 'events', label: () => t('nav.events') },
		{ href: resolve('/groups'), icon: 'groups', label: () => t('nav.groups') },
		{ href: resolve('/notifications'), icon: 'notifications', label: () => t('nav.notifications') },
		{ href: resolve('/you'), icon: 'you', label: () => t('nav.you') }
	];

	const root = resolve('/');

	function isActive(href: string): boolean {
		const path = page.url.pathname;
		return href === root ? path === root : path === href || path.startsWith(`${href}/`);
	}
</script>

<div class="min-h-dvh md:flex">
	<a
		href="#main"
		class="sr-only focus-visible:not-sr-only focus-visible:fixed focus-visible:top-2 focus-visible:left-2 focus-visible:z-50 focus-visible:rounded-lg focus-visible:bg-surface focus-visible:px-3 focus-visible:py-2 focus-visible:text-sm focus-visible:text-ink"
	>
		{t('a11y.skipToContent')}
	</a>

	<!-- Desktop: left sidebar, same IA as the mobile tab bar (SPEC.md §21). -->
	<aside class="sticky top-0 hidden h-dvh w-60 shrink-0 border-r border-line md:block">
		<div class="flex h-full flex-col px-4 py-6">
			<p class="px-3 text-lg font-semibold tracking-tight text-ink">{t('app.name')}</p>
			<nav aria-label={t('nav.label')} class="mt-8 flex flex-col gap-1">
				{#each tabs as tab (tab.href)}
					<!-- tab.href values are pre-resolved via resolve() in `tabs` above -->
					<!-- eslint-disable svelte/no-navigation-without-resolve -->
					<a
						href={tab.href}
						aria-current={isActive(tab.href) ? 'page' : undefined}
						class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors duration-150 {isActive(
							tab.href
						)
							? 'bg-ink/5 font-medium text-ink'
							: 'text-ink-muted hover:bg-ink/5 hover:text-ink'}"
					>
						<TabIcon name={tab.icon} class="size-5" />
						{tab.label()}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				{/each}
			</nav>
		</div>
	</aside>

	<div class="min-w-0 flex-1">
		<main id="main" class="mx-auto w-full max-w-2xl px-4 pt-6 pb-24 md:px-8 md:pt-10 md:pb-16">
			{#if instances.list.length > 0}
				<!-- One broken render (a single bad post, say) degrades to this
				     inline card instead of white-screening the shell; the nav
				     stays outside the boundary so there is always a way out.
				     Logged to the console — the only sink there is (#270). -->
				<svelte:boundary onerror={(error) => console.error('[kammer] screen crashed', error)}>
					{@render children()}

					<!-- The error is logged in onerror above; the snippet only needs
					     reset, but snippet params are positional. -->
					<!-- eslint-disable-next-line @typescript-eslint/no-unused-vars -->
					{#snippet failed(_error, reset)}
						<div class="rounded-xl border border-line bg-surface">
							<EmptyState title={t('boundary.title')} body={t('boundary.body')}>
								<Button onclick={reset}>{t('common.retry')}</Button>
							</EmptyState>
						</div>
					{/snippet}
				</svelte:boundary>
			{/if}
		</main>
	</div>

	<!-- Mobile: bottom tab bar — Home · Events · Groups · Notifications · You. -->
	<nav
		aria-label={t('nav.label')}
		class="fixed inset-x-0 bottom-0 border-t border-line bg-surface pb-[env(safe-area-inset-bottom)] md:hidden"
	>
		<div class="grid grid-cols-5">
			{#each tabs as tab (tab.href)}
				<!-- tab.href values are pre-resolved via resolve() in `tabs` above -->
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					href={tab.href}
					aria-current={isActive(tab.href) ? 'page' : undefined}
					class="flex flex-col items-center gap-0.5 pt-2 pb-1.5 text-xs transition-colors duration-150 {isActive(
						tab.href
					)
						? 'text-accent'
						: 'text-ink-faint hover:text-ink-muted'}"
				>
					<TabIcon name={tab.icon} class="size-6" />
					{tab.label()}
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			{/each}
		</div>
	</nav>
</div>
