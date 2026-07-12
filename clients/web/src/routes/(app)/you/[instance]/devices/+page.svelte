<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError } from '$lib/feed/api.js';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import {
		beginPasskeyRegistration,
		completePasskeyRegistration,
		deletePasskey,
		fetchDevices,
		fetchPasskeys,
		revokeDevice
	} from '$lib/people/api.js';
	import type { Device, Passkey } from '$lib/people/types.js';
	import {
		createPasskey,
		isPasskeyRegistrationSupported,
		sameOriginInstance
	} from '$lib/instances/webauthn.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let devices = $state<Device[]>([]);
	let passkeys = $state<Passkey[]>([]);
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let actionError = $state<string | null>(null);
	let busy = $state(false);

	// Passkey enrollment (issue #260 port 5b) is its own little flow —
	// separate busy/error state so an add or remove there never blanks the
	// devices list above.
	let nickname = $state('');
	let passkeyBusy = $state(false);
	let passkeyError = $state<string | null>(null);

	// Browser capability is fixed for the session; the origin check is not
	// (it depends on which instance is open), so only the latter is derived.
	const browserSupportsPasskeys = isPasskeyRegistrationSupported();
	const canAddPasskey = $derived(
		!!instance && browserSupportsPasskeys && sameOriginInstance(instance.baseUrl)
	);

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				// Both are this account's credentials on the same server behind
				// the same token — load them together and share one state.
				const [nextDevices, nextPasskeys] = await Promise.all([
					fetchDevices(inst),
					fetchPasskeys(inst)
				]);
				if (cancelled) return;
				devices = nextDevices;
				passkeys = nextPasskeys;
				loadState = 'ready';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function revoke(device: Device): Promise<void> {
		if (!instance) return;
		if (!window.confirm(t('devices.revokeConfirm'))) return;
		busy = true;
		actionError = null;
		try {
			await revokeDevice(instance, device.id);
			devices = await fetchDevices(instance);
		} catch (error) {
			actionError = error instanceof ApiError ? error.message : t('devices.error.body');
		} finally {
			busy = false;
		}
	}

	async function addPasskey(): Promise<void> {
		if (!instance) return;
		passkeyBusy = true;
		passkeyError = null;
		try {
			const challenge = await beginPasskeyRegistration(instance);
			const attestation = await createPasskey({
				challenge: challenge.challenge,
				rpId: challenge.rp_id,
				userId: challenge.user_id,
				userName: challenge.user_name,
				// The WebAuthn user.displayName must be a string; fall back to
				// the account name when the profile has none.
				userDisplayName: challenge.user_display_name ?? challenge.user_name,
				excludeCredentials: challenge.exclude_credentials
			});
			// Null means the browser produced no credential — almost always a
			// dismissed prompt. A deliberate cancel isn't a failure, so stay
			// silent (as the sign-in flow and the LiveView it ports both do).
			if (!attestation) return;
			await completePasskeyRegistration(instance, {
				challenge_token: challenge.challenge_token,
				attestation_object: attestation.attestation_object,
				client_data_json: attestation.client_data_json,
				nickname: nickname.trim() || null
			});
			nickname = '';
			// The credential is registered; a refetch failure here must not
			// report the (successful) add as failed — the list just refreshes
			// on the next load.
			try {
				passkeys = await fetchPasskeys(instance);
			} catch {
				/* keep the current list; it refreshes on reload */
			}
		} catch (error) {
			// A user dismissing the browser's passkey prompt (NotAllowedError /
			// AbortError) is a deliberate cancel, not a failure — stay silent,
			// as the LiveView it ports did. Anything else collapses to one
			// neutral message, mirroring the server's 422.
			if (!isUserCancellation(error)) passkeyError = t('passkeys.error');
		} finally {
			passkeyBusy = false;
		}
	}

	// A WebAuthn prompt the user dismissed throws NotAllowedError (or
	// AbortError on timeout); treat those as a quiet cancel, not an error.
	function isUserCancellation(error: unknown): boolean {
		const name = (error as { name?: string } | null)?.name;
		return name === 'NotAllowedError' || name === 'AbortError';
	}

	async function removePasskey(passkey: Passkey): Promise<void> {
		if (!instance) return;
		if (!window.confirm(t('passkeys.removeConfirm'))) return;
		passkeyBusy = true;
		passkeyError = null;
		try {
			await deletePasskey(instance, passkey.id);
			// Removed server-side; a refetch failure must not report the
			// (successful) removal as failed — the list refreshes on reload.
			try {
				passkeys = await fetchPasskeys(instance);
			} catch {
				/* keep the current list; it refreshes on reload */
			}
		} catch (error) {
			passkeyError = error instanceof ApiError ? error.message : t('passkeys.error');
		} finally {
			passkeyBusy = false;
		}
	}

	const backHref = resolve('/you');
</script>

<svelte:head>
	<title>{t('devices.title')} · {t('app.name')}</title>
</svelte:head>

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
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('devices.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">
				{t('devices.description', { name: instance.instanceName })}
			</p>
		</div>
	</header>

	{#if loadState === 'loading'}
		<div class="flex flex-col gap-3">
			{#each [0, 1] as skeleton (skeleton)}
				<div class="rounded-xl border border-line bg-surface p-4">
					<Skeleton class="h-4 w-56" />
				</div>
			{/each}
		</div>
	{:else if loadState === 'error'}
		<EmptyState title={t('devices.error.title')} body={t('devices.error.body')} />
	{:else}
		{#if actionError}
			<div
				class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{actionError}
			</div>
		{/if}

		<Card class="divide-y divide-line">
			{#each devices as device (device.id)}
				<ListItem>
					<p class="truncate text-sm font-medium text-ink">
						{device.device_name ?? t('devices.unnamed')}
					</p>
					<p class="truncate text-xs text-ink-muted">
						{t('devices.added', { date: formatDate(device.created_at, i18n.locale) })}
					</p>
					{#snippet trailing()}
						<span class="flex items-center gap-1.5">
							<Chip>{t(`devices.kind.${device.kind}`)}</Chip>
							{#if device.current}
								<Chip tone="accent">{t('devices.current')}</Chip>
							{:else}
								<Button
									size="sm"
									variant="danger"
									disabled={busy}
									onclick={() => void revoke(device)}
								>
									{t('devices.revoke')}
								</Button>
							{/if}
						</span>
					{/snippet}
				</ListItem>
			{/each}
		</Card>

		<section class="mt-10">
			<h2 class="text-lg font-semibold tracking-tight text-ink">{t('passkeys.title')}</h2>
			<p class="mt-0.5 text-sm text-ink-muted">
				{t('passkeys.description', { name: instance.instanceName })}
			</p>

			{#if passkeyError}
				<div
					class="mt-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
					role="alert"
				>
					{passkeyError}
				</div>
			{/if}

			{#if canAddPasskey}
				<div class="mt-4 flex flex-col gap-3">
					<Input
						id="passkey-nickname"
						label={t('passkeys.nicknameLabel')}
						bind:value={nickname}
						placeholder={t('passkeys.nicknamePlaceholder')}
						type="text"
						autocomplete="off"
					/>
					<Button
						id="passkey-add"
						variant="primary"
						disabled={passkeyBusy}
						onclick={() => void addPasskey()}
					>
						{passkeyBusy ? t('passkeys.adding') : t('passkeys.add')}
					</Button>
				</div>
			{:else}
				<p class="mt-4 text-sm text-ink-faint">
					{browserSupportsPasskeys ? t('passkeys.crossOrigin') : t('passkeys.unsupported')}
				</p>
			{/if}

			{#if passkeys.length === 0}
				<p class="mt-4 text-sm text-ink-muted">{t('passkeys.empty')}</p>
			{:else}
				<div id="passkey-list" class="mt-4">
					<Card class="divide-y divide-line">
						{#each passkeys as passkey (passkey.id)}
							<ListItem>
								<p class="truncate text-sm font-medium text-ink">
									{passkey.nickname ?? t('passkeys.unnamed')}
								</p>
								<p class="truncate text-xs text-ink-muted">
									{t('passkeys.added', { date: formatDate(passkey.created_at, i18n.locale) })}
									·
									{passkey.last_used_at
										? t('passkeys.lastUsed', {
												date: formatDate(passkey.last_used_at, i18n.locale)
											})
										: t('passkeys.neverUsed')}
								</p>
								{#snippet trailing()}
									<Button
										id="passkey-remove-{passkey.id}"
										size="sm"
										variant="danger"
										disabled={passkeyBusy}
										onclick={() => void removePasskey(passkey)}
									>
										{t('passkeys.remove')}
									</Button>
								{/snippet}
							</ListItem>
						{/each}
					</Card>
				</div>
			{/if}
		</section>
	{/if}
{/if}
