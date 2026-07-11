<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import {
		createCommunity,
		fetchCommunityCreationCapability,
		type CommunityParams
	} from '$lib/communities/api.js';
	import { FeedApiError } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Select from '$lib/ui/Select.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The instances this account may actually create a community on — the
	// per-viewer `can_create_community` capability, so the form never
	// offers an instance whose policy would 403 on submit.
	let allowed = $state<Instance[] | null>(null);
	let instanceId = $state('');
	let submitting = $state(false);
	let formError = $state<string | null>(null);
	let nameError = $state<string | null>(null);
	let slugError = $state<string | null>(null);

	let name = $state('');
	let slug = $state('');
	let slugTouched = $state(false);
	let description = $state('');
	let accent = $state('#3E6B48');
	let locale = $state('en');

	const selected = $derived(allowed?.find((candidate) => candidate.id === instanceId));

	$effect(() => {
		const list = instances.list;
		let cancelled = false;
		allowed = null;

		void (async () => {
			const capable = await Promise.all(
				list.map(async (instance) =>
					(await fetchCommunityCreationCapability(instance)) ? instance : null
				)
			);
			if (cancelled) return;
			const usable = capable.filter((instance): instance is Instance => instance !== null);
			allowed = usable;
			if (usable.length > 0) instanceId = usable[0].id;
		})();

		return () => {
			cancelled = true;
		};
	});

	// Suggest a slug from the name until the field is edited by hand —
	// same courtesy the LiveView flow offers.
	function suggestSlug(): void {
		if (slugTouched) return;
		slug = name
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '');
	}

	async function submit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (!selected || submitting) return;
		submitting = true;
		formError = null;
		nameError = null;
		slugError = null;
		const params: CommunityParams = {
			name,
			slug,
			description,
			accent_color: accent,
			default_locale: locale as CommunityParams['default_locale']
		};
		try {
			const community = await createCommunity(selected, params);
			await goto(resolve('/groups'));
			void community;
		} catch (cause) {
			if (cause instanceof FeedApiError && cause.kind === 'validation') {
				// Map field NAMES onto our copy; server message strings never
				// render (#253's direction).
				nameError = cause.details.name ? t('communities.new.error.name') : null;
				slugError = cause.details.slug ? t('communities.new.error.slug') : null;
				if (!nameError && !slugError) formError = t('communities.new.error.generic');
			} else if (cause instanceof FeedApiError && cause.kind === 'forbidden') {
				formError = t('communities.new.error.forbidden');
			} else {
				formError = t('communities.new.error.generic');
			}
		} finally {
			submitting = false;
		}
	}
</script>

<svelte:head><title>{t('communities.new.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-1 text-xl font-semibold tracking-tight text-ink">{t('communities.new.title')}</h1>
<p class="mb-5 text-sm text-ink-muted">{t('communities.new.subtitle')}</p>

{#if allowed === null}
	<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-24" /></div>
{:else if allowed.length === 0}
	<EmptyState
		title={t('communities.new.forbidden.title')}
		body={t('communities.new.forbidden.body')}
	/>
{:else}
	<form class="flex max-w-lg flex-col gap-4" onsubmit={submit}>
		{#if allowed.length > 1}
			<Select
				id="community-instance"
				label={t('communities.new.instance')}
				bind:value={instanceId}
				options={allowed.map((instance) => ({ value: instance.id, label: instance.instanceName }))}
			/>
		{/if}

		<Input
			id="community-name"
			label={t('communities.new.name')}
			bind:value={name}
			oninput={suggestSlug}
			error={nameError}
			required
		/>
		<Input
			id="community-slug"
			label={t('communities.new.slug')}
			hint={t('communities.new.slugHint')}
			bind:value={slug}
			oninput={() => (slugTouched = true)}
			error={slugError}
			required
		/>

		<div class="flex flex-col gap-1.5">
			<label for="community-description" class="text-sm font-medium text-ink">
				{t('communities.new.description')}
			</label>
			<textarea
				id="community-description"
				bind:value={description}
				rows="3"
				class="rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none"
			></textarea>
		</div>

		<div class="flex items-center gap-3">
			<label for="community-accent" class="text-sm font-medium text-ink">
				{t('communities.new.accent')}
			</label>
			<input
				id="community-accent"
				type="color"
				bind:value={accent}
				class="h-9 w-14 cursor-pointer rounded-lg border border-line bg-surface"
			/>
		</div>

		<Select
			id="community-locale"
			label={t('communities.new.locale')}
			bind:value={locale}
			options={[
				{ value: 'en', label: t('communities.new.localeEn') },
				{ value: 'da', label: t('communities.new.localeDa') }
			]}
		/>

		<div class="flex items-center gap-3">
			<Button type="submit" variant="primary" disabled={submitting}>
				{submitting ? t('common.sending') : t('communities.new.submit')}
			</Button>
			{#if formError}
				<span class="text-sm text-danger" role="alert">{formError}</span>
			{/if}
		</div>
	</form>
{/if}
