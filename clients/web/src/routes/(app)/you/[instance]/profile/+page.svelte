<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { createApiClient } from '$lib/api/client.js';
	import { fetchCommunities } from '$lib/events/api.js';
	import { FeedApiError } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { fetchProfile, updateProfile } from '$lib/people/api.js';
	import type { ContactVisibility, CustomField, Profile } from '$lib/people/types.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	interface CommunityProfileSection {
		community: Community;
		fields: CustomField[];
		values: Record<string, string>;
		missing: string[];
		saving: boolean;
		saved: boolean;
	}

	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let profile = $state<Profile | null>(null);
	let sections = $state<CommunityProfileSection[]>([]);

	// Base profile form state, seeded from the fetched profile.
	let displayName = $state('');
	let bio = $state('');
	let pronouns = $state('');
	let contactPhone = $state('');
	let contactPhoneVisibility = $state<ContactVisibility>('hidden');
	let contactEmail = $state('');
	let contactEmailVisibility = $state<ContactVisibility>('hidden');
	let contactNote = $state('');
	let contactNoteVisibility = $state<ContactVisibility>('hidden');
	let saving = $state(false);
	let saved = $state(false);
	let saveError = $state<string | null>(null);

	function seed(next: Profile): void {
		profile = next;
		displayName = next.display_name;
		bio = next.bio ?? '';
		pronouns = next.pronouns ?? '';
		contactPhone = next.contact_phone ?? '';
		contactPhoneVisibility = next.contact_phone_visibility;
		contactEmail = next.contact_email ?? '';
		contactEmailVisibility = next.contact_email_visibility;
		contactNote = next.contact_note ?? '';
		contactNoteVisibility = next.contact_note_visibility;
	}

	async function loadCommunityProfile(
		inst: NonNullable<typeof instance>,
		community: Community
	): Promise<CommunityProfileSection | null> {
		const client = createApiClient(inst.baseUrl, inst.deviceToken);
		const { data, error } = await client.GET('/api/v1/communities/{community_slug}/profile', {
			params: { path: { community_slug: community.slug } }
		});
		if (error || !data) return null;
		if (data.data.fields.length === 0) return null;
		return {
			community,
			fields: data.data.fields,
			values: { ...data.data.values },
			missing: data.data.missing_required_field_ids,
			saving: false,
			saved: false
		};
	}

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				const [me, communities] = await Promise.all([fetchProfile(inst), fetchCommunities(inst)]);
				const loadedSections = await Promise.all(
					communities.map((community) => loadCommunityProfile(inst, community))
				);
				if (cancelled) return;
				seed(me);
				sections = loadedSections.filter((section) => section !== null);
				loadState = 'ready';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function save(submitEvent: SubmitEvent): Promise<void> {
		submitEvent.preventDefault();
		if (!instance) return;
		saving = true;
		saved = false;
		saveError = null;
		try {
			const next = await updateProfile(instance, {
				display_name: displayName.trim(),
				bio: bio.trim() || null,
				pronouns: pronouns.trim() || null,
				contact_phone: contactPhone.trim() || null,
				contact_phone_visibility: contactPhoneVisibility,
				contact_email: contactEmail.trim() || null,
				contact_email_visibility: contactEmailVisibility,
				contact_note: contactNote.trim() || null,
				contact_note_visibility: contactNoteVisibility
			});
			seed(next);
			saved = true;
		} catch (error) {
			saveError = error instanceof FeedApiError ? error.message : t('profile.error.body');
		} finally {
			saving = false;
		}
	}

	async function saveSection(section: CommunityProfileSection): Promise<void> {
		if (!instance) return;
		section.saving = true;
		section.saved = false;
		saveError = null;
		try {
			const client = createApiClient(instance.baseUrl, instance.deviceToken);
			const { data, error } = await client.PUT('/api/v1/communities/{community_slug}/profile', {
				params: { path: { community_slug: section.community.slug } },
				body: { values: section.values }
			});
			if (error || !data) throw new FeedApiError('server', t('profile.error.body'), null);
			section.values = { ...data.data.values };
			section.missing = data.data.missing_required_field_ids;
			section.saved = true;
		} catch (error) {
			saveError = error instanceof FeedApiError ? error.message : t('profile.error.body');
		} finally {
			section.saving = false;
		}
	}

	const visibilityOptions: { value: ContactVisibility; label: () => string }[] = [
		{ value: 'hidden', label: () => t('profile.visibility.hidden') },
		{ value: 'members', label: () => t('profile.visibility.members') },
		{ value: 'admins', label: () => t('profile.visibility.admins') }
	];

	const selectClass =
		'h-11 rounded-lg border border-line bg-surface px-2 text-sm text-ink transition-colors duration-150 hover:border-ink-faint/60';

	const backHref = resolve('/you');
</script>

<svelte:head>
	<title>{t('profile.title')} · {t('app.name')}</title>
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
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('profile.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">
				{t('profile.description', { name: instance.instanceName })}
			</p>
		</div>
	</header>

	{#if loadState === 'loading'}
		<div class="flex flex-col gap-4">
			<Skeleton class="h-11 w-full" />
			<Skeleton class="h-24 w-full" />
			<Skeleton class="h-11 w-2/3" />
		</div>
	{:else if loadState === 'error' || !profile}
		<EmptyState title={t('profile.error.title')} body={t('profile.error.body')} />
	{:else}
		{#if saveError}
			<div
				class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{saveError}
			</div>
		{/if}

		<form class="flex flex-col gap-4" onsubmit={save} id="profile-form">
			<Input id="profile-display-name" label={t('profile.displayName')} bind:value={displayName} />

			<label class="flex flex-col gap-1.5">
				<span class="text-sm font-medium text-ink">{t('profile.bio')}</span>
				<textarea
					id="profile-bio"
					bind:value={bio}
					rows="3"
					maxlength="500"
					class="w-full resize-y rounded-lg border border-line bg-surface px-3 py-2 text-base text-ink"
				></textarea>
			</label>

			<Input id="profile-pronouns" label={t('profile.pronouns')} bind:value={pronouns} />

			<h2 class="mt-4 text-sm font-medium text-ink">{t('profile.contact.title')}</h2>
			<p class="-mt-3 text-sm text-ink-muted">{t('profile.contact.description')}</p>

			{#each [{ id: 'phone', label: t('profile.contact.phone') }, { id: 'email', label: t('profile.contact.email') }, { id: 'note', label: t('profile.contact.note') }] as contact (contact.id)}
				<div class="flex items-end gap-2">
					{#if contact.id === 'phone'}
						<Input
							id="profile-contact-phone"
							label={contact.label}
							bind:value={contactPhone}
							class="flex-1"
						/>
						<select
							aria-label={t('profile.visibilityFor', { field: contact.label })}
							bind:value={contactPhoneVisibility}
							class={selectClass}
						>
							{#each visibilityOptions as option (option.value)}
								<option value={option.value}>{option.label()}</option>
							{/each}
						</select>
					{:else if contact.id === 'email'}
						<Input
							id="profile-contact-email"
							label={contact.label}
							bind:value={contactEmail}
							class="flex-1"
						/>
						<select
							aria-label={t('profile.visibilityFor', { field: contact.label })}
							bind:value={contactEmailVisibility}
							class={selectClass}
						>
							{#each visibilityOptions as option (option.value)}
								<option value={option.value}>{option.label()}</option>
							{/each}
						</select>
					{:else}
						<Input
							id="profile-contact-note"
							label={contact.label}
							bind:value={contactNote}
							class="flex-1"
						/>
						<select
							aria-label={t('profile.visibilityFor', { field: contact.label })}
							bind:value={contactNoteVisibility}
							class={selectClass}
						>
							{#each visibilityOptions as option (option.value)}
								<option value={option.value}>{option.label()}</option>
							{/each}
						</select>
					{/if}
				</div>
			{/each}

			<div class="flex items-center gap-3">
				<Button
					type="submit"
					variant="primary"
					disabled={saving || displayName.trim() === ''}
					id="profile-save"
				>
					{t('common.save')}
				</Button>
				{#if saved}
					<span class="text-sm text-ink-muted" role="status">{t('profile.saved')}</span>
				{/if}
			</div>
		</form>

		{#each sections as section (section.community.id)}
			<section class="mt-10" aria-labelledby="community-profile-{section.community.id}">
				<h2 id="community-profile-{section.community.id}" class="text-sm font-medium text-ink">
					{t('profile.communityFields.title', { name: section.community.name })}
				</h2>
				<p class="mt-1 text-sm text-ink-muted">{t('profile.communityFields.description')}</p>
				{#if section.missing.length > 0}
					<p
						class="mt-2 rounded-lg border border-accent/30 bg-accent/5 px-3 py-2 text-sm text-accent"
					>
						{t('profile.communityFields.missing')}
					</p>
				{/if}

				<div class="mt-4 flex flex-col gap-4">
					{#each section.fields as field (field.id)}
						<label class="flex flex-col gap-1.5">
							<span class="text-sm font-medium text-ink">
								{field.label}
								{#if field.required}
									<span class="font-normal text-ink-faint">
										· {t('profile.communityFields.required')}</span
									>
								{/if}
							</span>
							{#if field.field_type === 'single_select'}
								<select
									value={section.values[field.id] ?? ''}
									onchange={(changeEvent) => {
										section.values = {
											...section.values,
											[field.id]: changeEvent.currentTarget.value
										};
									}}
									class={selectClass}
								>
									<option value=""></option>
									{#each field.options as option (option)}
										<option value={option}>{option}</option>
									{/each}
								</select>
							{:else}
								<input
									value={section.values[field.id] ?? ''}
									oninput={(inputEvent) => {
										section.values = {
											...section.values,
											[field.id]: inputEvent.currentTarget.value
										};
									}}
									class="h-11 w-full rounded-lg border border-line bg-surface px-3 text-base text-ink"
								/>
							{/if}
						</label>
					{/each}

					<div class="flex items-center gap-3">
						<Button
							variant="secondary"
							disabled={section.saving}
							onclick={() => void saveSection(section)}
						>
							{t('common.save')}
						</Button>
						{#if section.saved}
							<span class="text-sm text-ink-muted" role="status">{t('profile.saved')}</span>
						{/if}
					</div>
				</div>
			</section>
		{/each}
	{/if}
{/if}
