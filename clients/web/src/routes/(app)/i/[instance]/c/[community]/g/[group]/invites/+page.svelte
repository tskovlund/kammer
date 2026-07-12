<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError, fetchGroup } from '$lib/feed/api.js';
	import type { Group } from '$lib/feed/api.js';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import {
		createGroupInvite,
		fetchGroupInvites,
		inviteUrl,
		revokeInvite
	} from '$lib/people/api.js';
	import type { Invite } from '$lib/people/types.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);
	const groupRef = $derived({ community: page.params.community!, group: page.params.group! });

	let group = $state<Group | null>(null);
	let invites = $state<Invite[]>([]);
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let actionError = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let busy = $state(false);
	let email = $state('');
	let copiedId = $state<string | null>(null);

	$effect(() => {
		const inst = instance;
		if (!inst || !page.params.community || !page.params.group) return;

		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				const ref = { community: page.params.community!, group: page.params.group! };
				const [resolvedGroup, resolvedInvites] = await Promise.all([
					fetchGroup(inst, ref.community, ref.group),
					fetchGroupInvites(inst, ref)
				]);
				if (cancelled) return;
				group = resolvedGroup;
				invites = resolvedInvites;
				loadState = 'ready';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function reload(): Promise<void> {
		if (!instance) return;
		invites = await fetchGroupInvites(instance, groupRef);
	}

	function report(error: unknown): void {
		actionError = error instanceof ApiError ? error.message : t('groups.error.body');
	}

	async function newLink(): Promise<void> {
		if (!instance) return;
		busy = true;
		actionError = null;
		notice = null;
		try {
			await createGroupInvite(instance, groupRef);
			await reload();
		} catch (error) {
			report(error);
		} finally {
			busy = false;
		}
	}

	async function sendEmailInvite(submitEvent: SubmitEvent): Promise<void> {
		submitEvent.preventDefault();
		const invitedEmail = email.trim();
		if (!instance || !invitedEmail) return;
		busy = true;
		actionError = null;
		notice = null;
		try {
			await createGroupInvite(instance, groupRef, { invited_email: invitedEmail, max_uses: 1 });
			notice = t('invites.emailSent', { email: invitedEmail });
			email = '';
			await reload();
		} catch (error) {
			report(error);
		} finally {
			busy = false;
		}
	}

	async function revoke(invite: Invite): Promise<void> {
		if (!instance) return;
		busy = true;
		actionError = null;
		try {
			// Group invites are revoked through the shared community-scoped
			// endpoint (the token, not the scope, identifies the invite).
			await revokeInvite(instance, groupRef.community, invite.id);
			await reload();
		} catch (error) {
			report(error);
		} finally {
			busy = false;
		}
	}

	async function copy(invite: Invite): Promise<void> {
		if (!instance) return;
		try {
			await navigator.clipboard.writeText(inviteUrl(instance, invite));
			copiedId = invite.id;
			setTimeout(() => {
				if (copiedId === invite.id) copiedId = null;
			}, 2000);
		} catch {
			// Clipboard access denied — the link stays visible in the row.
		}
	}

	function usage(invite: Invite): string {
		if (invite.max_uses) {
			return t('invites.usesOf', {
				count: String(invite.use_count),
				max: String(invite.max_uses)
			});
		}
		return t('invites.uses', { count: String(invite.use_count) });
	}

	const backHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/settings`)
	);
</script>

<svelte:head>
	<title>{t('invites.title')} · {t('app.name')}</title>
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
			{group?.name ?? t('common.back')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('invites.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">{t('invites.groupDescription')}</p>
		</div>
	</header>

	{#if loadState === 'loading'}
		<div class="flex flex-col gap-3">
			{#each [0, 1] as skeleton (skeleton)}
				<div class="rounded-xl border border-line bg-surface p-4">
					<Skeleton class="h-4 w-64" />
				</div>
			{/each}
		</div>
	{:else if loadState === 'error'}
		<EmptyState title={t('invites.error.title')} body={t('invites.error.groupBody')} />
	{:else}
		{#if actionError}
			<div
				class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{actionError}
			</div>
		{/if}
		{#if notice}
			<div
				class="mb-4 rounded-lg border border-accent/30 bg-accent/5 px-3 py-2 text-sm text-accent"
				role="status"
			>
				{notice}
			</div>
		{/if}

		<div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
			<form class="flex flex-1 items-end gap-2" onsubmit={sendEmailInvite}>
				<Input
					id="invite-email"
					label={t('invites.emailLabel')}
					type="email"
					placeholder={t('invites.emailPlaceholder')}
					bind:value={email}
					class="flex-1"
				/>
				<Button type="submit" variant="secondary" disabled={busy || email.trim() === ''}>
					{t('invites.emailSend')}
				</Button>
			</form>
			<Button id="new-invite-link" variant="primary" disabled={busy} onclick={() => void newLink()}>
				{t('invites.newLink')}
			</Button>
		</div>

		{#if invites.length === 0}
			<div class="mt-6">
				<EmptyState title={t('invites.empty.title')} body={t('invites.empty.body')} />
			</div>
		{:else}
			<Card class="mt-6 divide-y divide-line">
				{#each invites as invite (invite.id)}
					<ListItem>
						<p class="truncate font-mono text-xs text-ink">{inviteUrl(instance, invite)}</p>
						<p class="mt-0.5 truncate text-xs text-ink-muted">
							{usage(invite)}
							{#if invite.invited_email}
								· {t('invites.emailBound', { email: invite.invited_email })}
							{/if}
							{#if invite.expires_at}
								· {t('invites.expires', { date: formatDate(invite.expires_at, i18n.locale) })}
							{/if}
						</p>
						{#snippet trailing()}
							<span class="flex items-center gap-1.5">
								<Button size="sm" variant="ghost" onclick={() => void copy(invite)}>
									{copiedId === invite.id ? t('invites.copied') : t('invites.copy')}
								</Button>
								<Button
									size="sm"
									variant="danger"
									disabled={busy}
									onclick={() => void revoke(invite)}
								>
									{t('invites.revoke')}
								</Button>
							</span>
						{/snippet}
					</ListItem>
				{/each}
			</Card>
		{/if}
	{/if}
{/if}
