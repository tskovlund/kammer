<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { createRosterStore, type RosterStore } from '$lib/people/roster-store.svelte.js';
	import type { Member } from '$lib/people/types.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let store = $state<RosterStore | null>(null);
	let community = $state<Community | null>(null);
	let metaError = $state(false);

	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		if (!inst || !communitySlug) return;

		let cancelled = false;
		const localStore = createRosterStore(inst, communitySlug);
		store = localStore;
		community = null;
		metaError = false;

		void (async () => {
			try {
				const [resolvedCommunity] = await Promise.all([
					fetchCommunity(inst, communitySlug),
					localStore.load()
				]);
				if (!cancelled) community = resolvedCommunity;
			} catch {
				if (!cancelled) metaError = true;
			}
		})();

		return () => {
			cancelled = true;
			localStore.stop();
		};
	});

	// The server enforces; viewer_can only decides which controls render
	// (#199) — so a member never meets a 403-on-click surface here.
	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);

	// The one line under a member's name: pronouns, visible contact
	// details, and visible custom-field answers, already redacted
	// server-side for this viewer (ADR 0020).
	function metaLine(member: Member): string {
		const contact = member.contact;
		const values = (store?.fields ?? [])
			.filter((field) => member.custom_field_values[field.id])
			.map((field) => `${field.label}: ${member.custom_field_values[field.id]}`);

		return [member.user.pronouns, contact.phone, contact.email, contact.note, ...values]
			.filter(Boolean)
			.join(' · ');
	}

	function roleLabel(role: Member['role']): string {
		return t(`groups.role.${role}`);
	}

	function manageable(member: Member): boolean {
		return canManage && member.role !== 'owner' && member.user.id !== instance?.user.id;
	}

	function removeMember(member: Member): void {
		if (window.confirm(t('members.removeConfirm', { name: member.user.display_name }))) {
			void store?.remove(member);
		}
	}

	const backHref = $derived(resolve('/groups'));
</script>

<svelte:head>
	<title>{t('members.title')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{community?.name ?? t('common.back')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('members.title')}</h1>
			{#if store && store.loadState === 'ready'}
				<p class="mt-0.5 text-sm text-ink-muted">
					{t('members.count', { count: String(store.members.length) })}
				</p>
			{/if}
		</div>

		{#if store && store.filterableFields.length > 0}
			<div class="flex flex-wrap gap-2">
				{#each store.filterableFields as field (field.id)}
					<label class="flex items-center gap-2 text-sm text-ink-muted">
						<span>{field.label}</span>
						<select
							value={store.filter[field.id] ?? ''}
							onchange={(changeEvent) =>
								void store?.setFilter(field.id, changeEvent.currentTarget.value)}
							class="h-9 rounded-lg border border-line bg-surface px-2 text-sm text-ink"
						>
							<option value="">{t('members.filter.all')}</option>
							{#each field.options as option (option)}
								<option value={option}>{option}</option>
							{/each}
						</select>
					</label>
				{/each}
			</div>
		{/if}
	</header>

	{#if metaError || store?.loadState === 'error'}
		<EmptyState title={t('members.error.title')} body={t('members.error.body')} />
	{:else if !store || store.loadState === 'loading' || store.loadState === 'idle'}
		<div class="flex flex-col gap-3">
			{#each [0, 1, 2] as skeleton (skeleton)}
				<div class="flex items-center gap-3 rounded-xl border border-line bg-surface p-4">
					<Skeleton class="size-10 rounded-full" />
					<Skeleton class="h-4 w-40" />
				</div>
			{/each}
		</div>
	{:else}
		{#if store.actionError}
			<div
				class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				<span>{store.actionError.message}</span>
				<button
					type="button"
					class="shrink-0 text-danger/70 hover:text-danger"
					aria-label={t('common.dismiss')}
					onclick={() => store?.clearActionError()}
				>
					✕
				</button>
			</div>
		{/if}

		<Card class="divide-y divide-line">
			{#each store.members as member (member.user.id)}
				<ListItem>
					{#snippet leading()}
						<Avatar
							author={{ type: 'user', id: member.user.id, display_name: member.user.display_name }}
						/>
					{/snippet}
					<p class="truncate text-sm font-medium text-ink">
						{member.user.display_name}
					</p>
					{#if metaLine(member)}
						<p class="truncate text-xs text-ink-muted">{metaLine(member)}</p>
					{/if}
					{#snippet trailing()}
						<span class="flex items-center gap-1.5">
							{#if member.role !== 'member'}
								<Chip tone="accent">{roleLabel(member.role)}</Chip>
							{/if}
							{#if manageable(member)}
								{#if member.role === 'member'}
									<Button
										size="sm"
										variant="ghost"
										disabled={store?.busy}
										onclick={() => void store?.changeRole(member, 'admin')}
									>
										{t('members.makeAdmin')}
									</Button>
								{:else if member.role === 'admin'}
									<Button
										size="sm"
										variant="ghost"
										disabled={store?.busy}
										onclick={() => void store?.changeRole(member, 'member')}
									>
										{t('members.removeAdmin')}
									</Button>
								{/if}
								<Button
									size="sm"
									variant="danger"
									disabled={store?.busy}
									aria-label={t('members.actions', { name: member.user.display_name })}
									onclick={() => removeMember(member)}
								>
									{t('members.remove')}
								</Button>
							{/if}
						</span>
					{/snippet}
				</ListItem>
			{/each}
		</Card>
	{/if}
{/if}
