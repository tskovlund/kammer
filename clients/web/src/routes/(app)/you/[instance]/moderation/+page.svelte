<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError, errorKind, type ApiErrorKind } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import {
		createInstanceBan,
		fetchInstanceBans,
		liftInstanceBan,
		type Ban
	} from '$lib/manage/api.js';
	import { isBanEmailValid } from '$lib/moderation/ban-email.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// Instance-wide email bans (SPEC §11, issue #259) — the operator-only
	// twin of the community moderation page: blocks rejoin on EVERY
	// community, not just one. The ban-list read is the gate — a
	// non-operator's 403 renders the forbidden state, same as the
	// instance settings page.
	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let bans = $state<Ban[]>([]);
	let loading = $state(true);
	let error = $state<ApiErrorKind | null>(null);
	let actionError = $state<ApiErrorKind | null>(null);
	// Ids currently mid-lift, so their buttons disable individually.
	let busy = $state<string[]>([]);

	// Ban-creation form: unlike the community ban's roster pick, an
	// instance ban is keyed on the email itself (it can block an address
	// with no account yet), so this is a plain email field — the same
	// form the LiveView poses.
	let banEmail = $state('');
	let banReason = $state('');
	let banning = $state(false);
	let banError = $state<string | null>(null);

	const backHref = resolve('/you');

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loading = true;
		error = null;
		banEmail = '';
		banReason = '';
		banError = null;
		banning = false;

		(async () => {
			try {
				const resolved = await fetchInstanceBans(inst);
				if (cancelled) return;
				bans = resolved;
			} catch (cause) {
				if (!cancelled) error = errorKind(cause);
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function onBan(event: SubmitEvent) {
		event.preventDefault();
		const email = banEmail.trim();
		if (!instance || !email || banning) return;
		// Clear any prior error on a fresh attempt, so an early return below
		// (a rejected address, or a cancelled confirm) never leaves a stale
		// message pointing at the address the operator just corrected.
		banError = null;
		// Reject a malformed address up front so the server's remaining `email`
		// 422 can only mean already-banned — otherwise a format-rejected address
		// would read as "already banned" (#276). Belt-and-suspenders: the input's
		// type="email" already blocks a bad format and the maxlength blocks an
		// over-long one, so this only bites in a browser that skips native
		// validation. Mirrors the server rule exactly (see ban-email.ts).
		if (!isBanEmailValid(email)) {
			banError = t('manage.instanceModeration.ban.errorInvalidEmail');
			return;
		}
		if (!window.confirm(t('manage.instanceModeration.ban.confirm', { email }))) return;
		banning = true;
		try {
			const ban = await createInstanceBan(instance, email, banReason.trim() || null);
			bans = [ban, ...bans];
			banEmail = '';
			banReason = '';
		} catch (cause) {
			// A 422's field names key our own copy — the server's English
			// message never renders (#253). `email` means the address already
			// carries an instance ban; `reason` is the 2000-character cap.
			if (cause instanceof ApiError && cause.kind === 'validation' && cause.details.email) {
				banError = t('manage.instanceModeration.ban.errorAlreadyBanned');
			} else if (cause instanceof ApiError && cause.kind === 'validation' && cause.details.reason) {
				banError = t('manage.moderation.ban.errorReason');
			} else if (cause instanceof ApiError && cause.kind === 'forbidden') {
				// The server refuses self-bans, other operators, and community
				// owners with a 403 the form can't foresee.
				banError = t('manage.instanceModeration.ban.errorRefused');
			} else {
				banError = t('manage.error.body');
			}
		} finally {
			banning = false;
		}
	}

	function onLift(ban: Ban) {
		if (!instance || busy.includes(ban.id)) return;
		if (!window.confirm(t('manage.instanceModeration.bans.liftConfirm'))) return;
		actionError = null;
		busy = [...busy, ban.id];
		void (async () => {
			try {
				await liftInstanceBan(instance!, ban.id);
				bans = bans.filter((candidate) => candidate.id !== ban.id);
			} catch (cause) {
				actionError = errorKind(cause);
			} finally {
				busy = busy.filter((candidate) => candidate !== ban.id);
			}
		})();
	}
</script>

<svelte:head><title>{t('manage.instanceModeration.title')} · {t('app.name')}</title></svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-6 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('nav.you')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">
				{t('manage.instanceModeration.title')}
			</h1>
			<p class="mt-0.5 text-sm text-ink-muted">{t('manage.instanceModeration.subtitle')}</p>
		</div>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
	{:else if error === 'forbidden'}
		<EmptyState
			title={t('manage.error.forbiddenTitle')}
			body={t('manage.instanceModeration.forbiddenBody')}
		/>
	{:else if error}
		<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
	{:else}
		<form class="flex max-w-lg flex-col gap-3" onsubmit={onBan}>
			<h2 class="text-sm font-medium text-ink">{t('manage.instanceModeration.ban.title')}</h2>
			<Input
				id="instance-ban-email"
				label={t('manage.instanceModeration.ban.email')}
				type="email"
				bind:value={banEmail}
				required
				maxlength={160}
			/>
			<Input
				id="instance-ban-reason"
				label={t('manage.moderation.ban.reason')}
				bind:value={banReason}
				maxlength={2000}
			/>
			<div class="flex items-center gap-3">
				<Button type="submit" variant="danger" disabled={banning || banEmail.trim() === ''}>
					{t('manage.instanceModeration.ban.submit')}
				</Button>
				{#if banError}
					<span class="text-sm text-danger" role="alert">{banError}</span>
				{/if}
			</div>
		</form>

		<section aria-labelledby="instance-bans-heading" class="mt-8">
			<h2 id="instance-bans-heading" class="mb-2 text-sm font-semibold text-ink-muted">
				{t('manage.instanceModeration.bans.title')}
			</h2>
			{#if actionError}
				<p class="mb-3 text-sm text-danger" role="alert">{t('manage.error.body')}</p>
			{/if}
			{#if bans.length === 0}
				<EmptyState title={t('manage.instanceModeration.bans.empty')} />
			{:else}
				<Card class="divide-y divide-line">
					{#each bans as ban (ban.id)}
						<div class="flex items-center gap-3 px-4 py-3">
							<div class="min-w-0 flex-1">
								<p class="truncate text-sm font-medium text-ink">{ban.email}</p>
								{#if ban.reason}
									<p class="truncate text-sm text-ink-muted">{ban.reason}</p>
								{/if}
								{#if ban.banned_by?.display_name}
									<p class="text-xs text-ink-faint">
										{t('manage.moderation.bans.by', { name: ban.banned_by.display_name })}
									</p>
								{/if}
							</div>
							<Button size="sm" disabled={busy.includes(ban.id)} onclick={() => onLift(ban)}>
								{t('manage.moderation.bans.lift')}
							</Button>
						</div>
					{/each}
				</Card>
			{/if}
		</section>
	{/if}
{/if}
