<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchGroup } from '$lib/feed/api.js';
	import {
		ManageApiError,
		approveJoinRequest,
		denyJoinRequest,
		fetchJoinRequests,
		loadErrorKind,
		setGroupArchived,
		setGroupFeatures,
		updateGroup,
		type GroupFeature,
		type GroupParams,
		type JoinRequest,
		type ManageErrorKind
	} from '$lib/manage/api.js';
	import type { Group } from '$lib/feed/api.js';
	import type { MessageKey } from '$lib/i18n/format.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The feed is always on and can't be toggled (ADR 0016); only these five
	// are member-facing switches.
	const TOGGLEABLE = ['events', 'files', 'availability', 'assignments', 'decisions'] as const;
	const FEATURE_LABEL: Record<(typeof TOGGLEABLE)[number], MessageKey> = {
		events: 'manage.group.features.events',
		files: 'manage.group.features.files',
		availability: 'manage.group.features.availability',
		assignments: 'manage.group.features.assignments',
		decisions: 'manage.group.features.decisions'
	};

	// The four presets and the policy enums (kept in lockstep with the
	// server's Group schema): each option's label is an i18n key.
	const VISIBILITY = ['private', 'community', 'public_link', 'public_listed'] as const;
	const JOIN_POLICY = ['invite_only', 'request_approval', 'open'] as const;
	const POSTING_POLICY = ['all_members', 'admins_only'] as const;
	const COMMENT_POLICY = ['members', 'members_and_guests', 'off'] as const;

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let group = $state<Group | null>(null);
	let joinRequests = $state<JoinRequest[]>([]);
	let loading = $state(true);
	let error = $state<ManageErrorKind | null>(null);
	let saving = $state(false);
	let saved = $state(false);

	let name = $state('');
	let slug = $state('');
	let description = $state('');
	let visibility = $state<string>('community');
	let joinPolicy = $state<string>('open');
	let postingPolicy = $state<string>('all_members');
	let commentPolicy = $state<string>('members');
	let approvalQueue = $state(false);
	let versionRetention = $state('');

	const canManage = $derived(group?.viewer_can.includes('manage_group') ?? false);
	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);
	const invitesHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}/invites`)
	);

	function hydrate(resolved: Group): void {
		group = resolved;
		name = resolved.name;
		slug = resolved.slug;
		description = resolved.description ?? '';
		visibility = resolved.visibility;
		joinPolicy = resolved.join_policy;
		// The four settings fields ride the group shape only for a manager
		// (the server gates them on manage_group); this page is manager-only,
		// so they're present at runtime — the fallbacks just satisfy the type,
		// which marks them optional for the public/non-manager shape.
		postingPolicy = resolved.posting_policy ?? 'all_members';
		commentPolicy = resolved.comment_policy ?? 'members';
		approvalQueue = resolved.approval_queue ?? false;
		versionRetention = resolved.version_retention == null ? '' : String(resolved.version_retention);
	}

	$effect(() => {
		const inst = instance;
		if (!inst || !page.params.community || !page.params.group) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				const resolved = await fetchGroup(inst, page.params.community!, page.params.group!);
				if (cancelled) return;
				hydrate(resolved);
				// Join requests are an approver-only surface; a non-manager's
				// 403 here shouldn't blank the settings form, so it's best-effort.
				if (resolved.viewer_can.includes('manage_members')) {
					try {
						joinRequests = await fetchJoinRequests(
							inst,
							page.params.community!,
							page.params.group!
						);
					} catch {
						if (!cancelled) joinRequests = [];
					}
				}
			} catch (cause) {
				if (!cancelled) error = loadErrorKind(cause);
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function run<T>(work: () => Promise<T>) {
		if (!instance || saving) return;
		saving = true;
		saved = false;
		error = null;
		try {
			await work();
			saved = true;
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
		} finally {
			saving = false;
		}
	}

	function saveDetails(event: SubmitEvent) {
		event.preventDefault();
		const params: GroupParams = {
			name,
			slug,
			description,
			visibility: visibility as GroupParams['visibility'],
			join_policy: joinPolicy as GroupParams['join_policy'],
			posting_policy: postingPolicy as GroupParams['posting_policy'],
			comment_policy: commentPolicy as GroupParams['comment_policy'],
			approval_queue: approvalQueue,
			version_retention: versionRetention.trim() === '' ? null : Number(versionRetention)
		};
		run(async () => {
			const updated = await updateGroup(instance!, communitySlug, groupSlug, params);
			hydrate(updated);
			// A slug change renames this page's own URL: the route param (and
			// every href derived from it, like the invites link) still says the
			// OLD slug — a refresh would 404 and the NEXT save would PUT to the
			// dead slug. Move to the new address in place.
			if (updated.slug !== groupSlug) {
				// An aborted navigation must not read as a save failure — the
				// PUT already succeeded.
				await goto(
					resolve(`/i/${page.params.instance}/c/${communitySlug}/g/${updated.slug}/settings`),
					{ replaceState: true }
				).catch(() => {});
			}
		});
	}

	function toggleFeature(feature: GroupFeature, on: boolean) {
		const current = group;
		if (!current) return;
		// The feed is forced on and never toggled (ADR 0016); rebuild the list
		// in canonical order from the toggleable set.
		const next: GroupFeature[] = [
			'feed',
			...TOGGLEABLE.filter((candidate) =>
				candidate === feature ? on : current.features.includes(candidate)
			)
		];
		run(async () => {
			// Update only `group` (which drives the feature checkboxes and the
			// archive banner) — NOT the detail-form fields. A feature toggle
			// fires immediately on change, so re-hydrating the whole form here
			// would silently revert any unsaved name/slug/policy edits.
			group = await setGroupFeatures(instance!, communitySlug, groupSlug, next);
		});
	}

	function toggleArchived() {
		if (!group) return;
		const archived = group.archived;
		run(async () => {
			// See toggleFeature: touch only `group`, leave unsaved edits intact.
			group = await setGroupArchived(instance!, communitySlug, groupSlug, !archived);
		});
	}

	async function resolveRequest(request: JoinRequest, approve: boolean) {
		if (!instance) return;
		saving = true;
		error = null;
		try {
			if (approve) {
				await approveJoinRequest(instance, communitySlug, groupSlug, request.id);
			} else {
				await denyJoinRequest(instance, communitySlug, groupSlug, request.id);
			}
			joinRequests = joinRequests.filter((candidate) => candidate.id !== request.id);
		} catch (cause) {
			error = cause instanceof ManageApiError ? cause.kind : 'server';
		} finally {
			saving = false;
		}
	}

	function option(prefix: string, value: string): { value: string; label: string } {
		return { value, label: t(`${prefix}.${value}` as MessageKey) };
	}
</script>

<svelte:head><title>{t('manage.group.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('manage.group.title')}</h1>

{#if loading}
	<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
{:else if error === 'forbidden' || (group && !canManage)}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if !group}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else}
	{#if group.archived}
		<p class="mb-4 rounded-lg border border-line bg-paper px-3 py-2 text-sm text-ink-muted">
			{t('manage.group.archived')}
		</p>
	{/if}

	<form class="flex max-w-lg flex-col gap-4" onsubmit={saveDetails}>
		<Input id="group-name" label={t('manage.group.name')} bind:value={name} required />
		<Input
			id="group-slug"
			label={t('manage.group.slug')}
			hint={t('manage.group.slugHint')}
			bind:value={slug}
			required
		/>

		<div class="flex flex-col gap-1.5">
			<label for="group-description" class="text-sm font-medium text-ink">
				{t('manage.group.description')}
			</label>
			<textarea
				id="group-description"
				bind:value={description}
				rows="3"
				class="rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none"
			></textarea>
		</div>

		<Select
			id="group-visibility"
			label={t('manage.group.visibility')}
			bind:value={visibility}
			options={VISIBILITY.map((v) => option('manage.group.visibilityOption', v))}
		/>
		<Select
			id="group-join-policy"
			label={t('manage.group.joinPolicy')}
			bind:value={joinPolicy}
			options={JOIN_POLICY.map((v) => option('manage.group.joinPolicyOption', v))}
		/>
		<Select
			id="group-posting-policy"
			label={t('manage.group.postingPolicy')}
			bind:value={postingPolicy}
			options={POSTING_POLICY.map((v) => option('manage.group.postingPolicyOption', v))}
		/>
		<Select
			id="group-comment-policy"
			label={t('manage.group.commentPolicy')}
			bind:value={commentPolicy}
			options={COMMENT_POLICY.map((v) => option('manage.group.commentPolicyOption', v))}
		/>

		<label class="flex items-center gap-2 text-sm text-ink">
			<input
				id="group-approval-queue"
				type="checkbox"
				bind:checked={approvalQueue}
				class="size-4 rounded border-line text-accent focus:ring-accent"
			/>
			{t('manage.group.approvalQueue')}
		</label>

		<Input
			id="group-version-retention"
			label={t('manage.group.versionRetention')}
			hint={t('manage.group.versionRetentionHint')}
			type="number"
			min="1"
			bind:value={versionRetention}
		/>

		<div class="flex items-center gap-3">
			<Button type="submit" variant="primary" disabled={saving}>
				{saving ? t('common.sending') : t('manage.group.save')}
			</Button>
			{#if saved}
				<span class="text-sm text-ink-muted" role="status">{t('manage.group.saved')}</span>
			{/if}
			{#if error}
				<span class="text-sm text-danger" role="alert">{t('manage.error.body')}</span>
			{/if}
		</div>
	</form>

	<section aria-labelledby="features-heading" class="mt-8 max-w-lg">
		<h2 id="features-heading" class="mb-2 text-sm font-semibold text-ink-muted">
			{t('manage.group.features.title')}
		</h2>
		<div class="flex flex-col gap-2">
			{#each TOGGLEABLE as feature (feature)}
				<label class="flex items-center gap-2 text-sm text-ink">
					<input
						type="checkbox"
						checked={group.features.includes(feature)}
						disabled={saving}
						onchange={(event) => toggleFeature(feature, event.currentTarget.checked)}
						class="size-4 rounded border-line text-accent focus:ring-accent"
					/>
					{t(FEATURE_LABEL[feature])}
				</label>
			{/each}
		</div>
	</section>

	{#if group.viewer_can.includes('manage_members')}
		<section aria-labelledby="join-requests-heading" class="mt-8 max-w-lg">
			<h2 id="join-requests-heading" class="mb-2 text-sm font-semibold text-ink-muted">
				{t('manage.group.joinRequests.title')}
			</h2>
			{#if joinRequests.length === 0}
				<p class="text-sm text-ink-faint">{t('manage.group.joinRequests.empty')}</p>
			{:else}
				<ul class="flex flex-col divide-y divide-line rounded-xl border border-line bg-surface">
					{#each joinRequests as request (request.id)}
						<li class="flex items-center justify-between gap-3 px-4 py-3">
							<div class="min-w-0">
								<p class="truncate text-sm font-medium text-ink">{request.user.display_name}</p>
								{#if request.message}
									<p class="truncate text-sm text-ink-muted">{request.message}</p>
								{/if}
							</div>
							<span class="flex shrink-0 items-center gap-1.5">
								<Button
									size="sm"
									variant="primary"
									disabled={saving}
									onclick={() => void resolveRequest(request, true)}
								>
									{t('manage.group.joinRequests.approve')}
								</Button>
								<Button
									size="sm"
									variant="ghost"
									disabled={saving}
									onclick={() => void resolveRequest(request, false)}
								>
									{t('manage.group.joinRequests.deny')}
								</Button>
							</span>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	{/if}

	<div class="mt-8 flex max-w-lg flex-col gap-4">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={invitesHref} class="text-sm text-accent hover:underline">
			{t('manage.group.invitesLink')}
		</a>
		<div>
			<Button variant="danger" disabled={saving} onclick={toggleArchived}>
				{group.archived ? t('manage.group.unarchive') : t('manage.group.archive')}
			</Button>
		</div>
	</div>
{/if}
