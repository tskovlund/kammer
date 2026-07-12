<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import { ManageApiError, createGroup, type GroupParams } from '$lib/manage/api.js';
	import type { MessageKey } from '$lib/i18n/format.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// Kept in lockstep with the server's Group schema; each option's label
	// is an i18n key (reusing the group-settings copy so the two forms read
	// identically).
	const VISIBILITY = ['private', 'community', 'public_link', 'public_listed'] as const;
	const JOIN_POLICY = ['invite_only', 'request_approval', 'open'] as const;
	const POSTING_POLICY = ['all_members', 'admins_only'] as const;
	const COMMENT_POLICY = ['members', 'members_and_guests', 'off'] as const;

	// Named suggestions (#278): a *starting shape* the operator picks and
	// then freely edits — never an auto-created group. Each pre-fills the
	// GroupParams-bound fields; the operator renames and re-tunes before
	// submitting. The lightweight front end of the #138 preset idea — the
	// label frames what they think they're making ("a public page"), not a
	// bundle of raw switches. Sensible community defaults are simply "no
	// suggestion".
	interface Suggestion {
		key: 'everyone' | 'announcements' | 'publicPage';
		visibility: (typeof VISIBILITY)[number];
		joinPolicy: (typeof JOIN_POLICY)[number];
		postingPolicy: (typeof POSTING_POLICY)[number];
	}
	const SUGGESTIONS: Suggestion[] = [
		{ key: 'everyone', visibility: 'community', joinPolicy: 'open', postingPolicy: 'all_members' },
		{
			key: 'announcements',
			visibility: 'community',
			joinPolicy: 'open',
			postingPolicy: 'admins_only'
		},
		{
			key: 'publicPage',
			visibility: 'public_listed',
			joinPolicy: 'request_approval',
			postingPolicy: 'admins_only'
		}
	];

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);
	const communitySlug = $derived(page.params.community!);

	let community = $state<Community | null>(null);
	let loadState = $state<'loading' | 'ready' | 'forbidden' | 'error'>('loading');
	let submitting = $state(false);
	let formError = $state<string | null>(null);
	let nameError = $state<string | null>(null);
	let slugError = $state<string | null>(null);

	let name = $state('');
	let nameTouched = $state(false);
	let slug = $state('');
	let slugTouched = $state(false);
	let description = $state('');
	let visibility = $state<string>('community');
	let joinPolicy = $state<string>('open');
	let postingPolicy = $state<string>('all_members');
	let commentPolicy = $state<string>('members');
	let approvalQueue = $state(false);
	let sealed = $state(false);

	$effect(() => {
		const inst = instance;
		if (!inst || !page.params.community) return;

		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				const resolved = await fetchCommunity(inst, page.params.community!);
				if (cancelled) return;
				community = resolved;
				// Gate on the same capability the empty-state CTA checks, so a
				// direct visit by a non-creator gets an honest forbidden state
				// rather than a form that 403s on submit.
				loadState = resolved.viewer_can.includes('create_group') ? 'ready' : 'forbidden';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	// Suggest a slug from the name until the field is edited by hand — the
	// same courtesy the community-creation and LiveView flows offer.
	function suggestSlug(): void {
		if (slugTouched) return;
		slug = name
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '');
	}

	function applySuggestion(suggestion: Suggestion): void {
		// Fills the policy shape always, and the name unless the operator has
		// typed their own (a *previous* suggestion's name is fair to replace,
		// so switching suggestions renames — hence `nameTouched`, set only on
		// real input, not `name` being non-empty). Every field stays editable
		// afterward: a starting point, not a lock.
		if (!nameTouched) {
			name = t(`groups.new.suggestion.${suggestion.key}.name` as MessageKey);
			suggestSlug();
		}
		visibility = suggestion.visibility;
		joinPolicy = suggestion.joinPolicy;
		postingPolicy = suggestion.postingPolicy;
	}

	async function submit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (!instance || submitting) return;
		submitting = true;
		formError = null;
		nameError = null;
		slugError = null;
		const params: GroupParams = {
			name,
			slug,
			description,
			visibility: visibility as GroupParams['visibility'],
			join_policy: joinPolicy as GroupParams['join_policy'],
			posting_policy: postingPolicy as GroupParams['posting_policy'],
			comment_policy: commentPolicy as GroupParams['comment_policy'],
			approval_queue: approvalQueue,
			sealed
		};
		try {
			const group = await createGroup(instance, communitySlug, params);
			await goto(resolve(`/i/${instance.id}/c/${communitySlug}/g/${group.slug}`));
		} catch (cause) {
			if (cause instanceof ManageApiError && cause.kind === 'validation') {
				// Map field NAMES onto our copy; server message strings never
				// render (#253's direction).
				nameError = cause.details.name ? t('groups.new.error.name') : null;
				slugError = cause.details.slug ? t('groups.new.error.slug') : null;
				if (!nameError && !slugError) formError = t('groups.new.error.generic');
			} else if (cause instanceof ManageApiError && cause.kind === 'forbidden') {
				formError = t('groups.new.error.forbidden');
			} else {
				formError = t('groups.new.error.generic');
			}
		} finally {
			submitting = false;
		}
	}

	function option(prefix: string, value: string): { value: string; label: string } {
		return { value, label: t(`${prefix}.${value}` as MessageKey) };
	}
</script>

<svelte:head><title>{t('groups.new.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-1 text-xl font-semibold tracking-tight text-ink">{t('groups.new.title')}</h1>
<p class="mb-5 text-sm text-ink-muted">
	{#if community}
		{t('groups.new.subtitle', { community: community.name })}
	{:else}
		{t('groups.new.subtitleGeneric')}
	{/if}
</p>

{#if loadState === 'loading'}
	<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
{:else if loadState === 'forbidden'}
	<EmptyState title={t('groups.new.forbidden.title')} body={t('groups.new.forbidden.body')} />
{:else if loadState === 'error'}
	<EmptyState title={t('groups.error.title')} body={t('groups.error.body')} />
{:else}
	<form class="flex max-w-lg flex-col gap-4" onsubmit={submit}>
		<fieldset class="flex flex-col gap-2">
			<legend class="mb-1 text-sm font-medium text-ink">{t('groups.new.suggestions.label')}</legend>
			<p class="mb-1 text-sm text-ink-muted">{t('groups.new.suggestions.hint')}</p>
			<div class="flex flex-wrap gap-2">
				{#each SUGGESTIONS as suggestion (suggestion.key)}
					<button
						type="button"
						id="group-suggestion-{suggestion.key}"
						onclick={() => applySuggestion(suggestion)}
						class="rounded-full border border-line bg-surface px-3 py-1.5 text-sm text-ink transition-colors duration-150 hover:border-accent hover:text-accent focus:border-accent focus:outline-none"
					>
						{t(`groups.new.suggestion.${suggestion.key}.name` as MessageKey)}
					</button>
				{/each}
			</div>
		</fieldset>

		<Input
			id="group-name"
			label={t('manage.group.name')}
			bind:value={name}
			oninput={() => {
				nameTouched = true;
				suggestSlug();
			}}
			error={nameError}
			required
		/>
		<Input
			id="group-slug"
			label={t('manage.group.slug')}
			hint={t('manage.group.slugHint')}
			bind:value={slug}
			oninput={() => (slugTouched = true)}
			error={slugError}
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

		<label class="flex items-start gap-2 text-sm text-ink">
			<input
				id="group-sealed"
				type="checkbox"
				bind:checked={sealed}
				class="mt-0.5 size-4 rounded border-line text-accent focus:ring-accent"
			/>
			<span>
				{t('groups.new.sealed')}
				<span class="block text-ink-muted">{t('groups.new.sealedHint')}</span>
			</span>
		</label>

		<div class="flex items-center gap-3">
			<Button id="group-create-submit" type="submit" variant="primary" disabled={submitting}>
				{submitting ? t('common.sending') : t('groups.new.submit')}
			</Button>
			{#if formError}
				<span class="text-sm text-danger" role="alert">{formError}</span>
			{/if}
		</div>
	</form>
{/if}
