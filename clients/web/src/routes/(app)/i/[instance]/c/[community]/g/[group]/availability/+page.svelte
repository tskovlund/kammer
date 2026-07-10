<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchGroup, type Group } from '$lib/feed/api.js';
	import { formatDate, formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import * as api from '$lib/tools/api.js';
	import type { AvailabilityAnswer, AvailabilityPoll, ToolsErrorKind } from '$lib/tools/api.js';
	import { pollsForGroup, tallyAnswers } from '$lib/tools/availability.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let group = $state<Group | null>(null);
	let polls = $state<AvailabilityPoll[]>([]);
	let loading = $state(true);
	// Load failure replaces the page; a per-action failure lands in
	// `actionError` so one bad answer never discards the loaded polls.
	let loadError = $state<ToolsErrorKind | null>(null);
	let actionError = $state<ToolsErrorKind | null>(null);
	let busy = $state<string[]>([]);

	// Create form.
	let creating = $state(false);
	let newTitle = $state('');
	let newDates = $state<string[]>(['']);

	const communitySlug = $derived(page.params.community!);
	const answers: AvailabilityAnswer[] = ['yes', 'if_needed', 'no'];

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !community || !groupSlug) return;

		let cancelled = false;
		loading = true;
		loadError = null;
		group = null;
		polls = [];

		(async () => {
			try {
				const resolvedGroup = await fetchGroup(inst, community, groupSlug);
				if (cancelled) return;
				group = resolvedGroup;
				const all = await api.fetchPolls(inst, community);
				if (cancelled) return;
				polls = pollsForGroup(all, resolvedGroup.id);
			} catch (cause) {
				if (!cancelled) loadError = api.toolsErrorKind(cause);
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	function mark(id: string, on: boolean) {
		busy = on ? [...busy, id] : busy.filter((candidate) => candidate !== id);
	}

	function replace(updated: AvailabilityPoll) {
		polls = polls.map((poll) => (poll.id === updated.id ? updated : poll));
	}

	async function act(id: string, run: () => Promise<void>) {
		if (!instance || busy.includes(id)) return;
		actionError = null;
		mark(id, true);
		try {
			await run();
		} catch (cause) {
			actionError = cause instanceof api.ToolsApiError ? cause.kind : 'server';
		} finally {
			mark(id, false);
		}
	}

	function answer(poll: AvailabilityPoll, optionId: string, value: AvailabilityAnswer) {
		act(`${poll.id}:${optionId}`, async () => {
			replace(
				await api.respondPoll(instance!, communitySlug, poll.id, {
					option_id: optionId,
					answer: value
				})
			);
		});
	}

	function close(poll: AvailabilityPoll) {
		act(poll.id, async () => {
			replace(await api.closePoll(instance!, communitySlug, poll.id));
		});
	}

	function convert(poll: AvailabilityPoll, optionId: string) {
		act(poll.id, async () => {
			replace(await api.convertPoll(instance!, communitySlug, poll.id, { option_id: optionId }));
		});
	}

	function addDate() {
		newDates = [...newDates, ''];
	}

	function removeDate(index: number) {
		newDates = newDates.filter((_, i) => i !== index);
	}

	function setDate(index: number, value: string) {
		newDates = newDates.map((date, i) => (i === index ? value : date));
	}

	async function submitPoll(event: SubmitEvent) {
		event.preventDefault();
		if (!instance || !group) return;
		const title = newTitle.trim();
		const options = newDates
			.map((local) => local.trim())
			.filter((local) => local !== '')
			.map((local) => new Date(local).toISOString());
		if (title === '' || options.length === 0) return;

		await act('new', async () => {
			const created = await api.createPoll(instance!, communitySlug, page.params.group!, {
				title,
				options
			});
			polls = [created, ...polls];
			newTitle = '';
			newDates = [''];
			creating = false;
		});
	}

	const groupHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/g/${page.params.group}`)
	);
</script>

<svelte:head>
	<title>{t('availability.title')} · {group?.name ?? t('nav.groups')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={groupHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{group?.name ?? t('common.back')}
		</a>
		<h1 class="text-xl font-semibold tracking-tight text-ink">{t('availability.title')}</h1>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3">
			<Skeleton class="h-28" />
			<Skeleton class="h-28" />
		</div>
	{:else if loadError === 'forbidden'}
		<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
	{:else if loadError === 'auth'}
		<EmptyState title={t('feed.error.authTitle')} body={t('feed.error.authBody')} />
	{:else if loadError}
		<EmptyState title={t('availability.error.title')} body={t('availability.error.body')} />
	{:else}
		{#if group?.my_role}
			<div class="mb-5">
				{#if creating}
					<Card class="p-4">
						<form class="flex flex-col gap-3" onsubmit={submitPoll}>
							<Input
								id="poll-title"
								label={t('availability.new.pollTitle')}
								bind:value={newTitle}
								maxlength={200}
								required
							/>
							<fieldset class="flex flex-col gap-2">
								{#each newDates as date, index (index)}
									<div class="flex items-end gap-2">
										<label class="flex flex-1 flex-col gap-1.5 text-sm font-medium text-ink">
											{t('availability.new.date', { n: String(index + 1) })}
											<input
												type="datetime-local"
												value={date}
												onchange={(e) => setDate(index, e.currentTarget.value)}
												class="h-11 w-full rounded-lg border border-line bg-surface px-3 text-base text-ink transition-colors duration-150 hover:border-ink-faint/60"
											/>
										</label>
										{#if newDates.length > 1}
											<Button
												variant="ghost"
												size="sm"
												onclick={() => removeDate(index)}
												aria-label={t('availability.new.removeDate')}
											>
												✕
											</Button>
										{/if}
									</div>
								{/each}
								<div>
									<Button variant="ghost" size="sm" onclick={addDate}>
										{t('availability.new.addDate')}
									</Button>
								</div>
							</fieldset>
							<div class="flex gap-2">
								<Button type="submit" variant="primary" size="sm" disabled={busy.includes('new')}>
									{t('availability.new.create')}
								</Button>
								<Button variant="ghost" size="sm" onclick={() => (creating = false)}>
									{t('common.cancel')}
								</Button>
							</div>
						</form>
					</Card>
				{:else}
					<Button variant="secondary" size="sm" onclick={() => (creating = true)}>
						{t('availability.new.open')}
					</Button>
				{/if}
			</div>
		{/if}

		{#if actionError}
			<p class="mb-4 text-sm text-danger" role="alert">
				{actionError === 'forbidden'
					? t('manage.error.forbiddenBody')
					: t('availability.error.body')}
			</p>
		{/if}

		{#if polls.length === 0}
			<EmptyState title={t('availability.empty.title')} body={t('availability.empty.body')} />
		{:else}
			<ul class="flex flex-col gap-4">
				{#each polls as poll (poll.id)}
					<li>
						<Card class="p-4">
							<div class="flex items-start justify-between gap-3">
								<div class="min-w-0">
									<h2 class="text-sm font-semibold text-ink">{poll.title}</h2>
									{#if poll.created_by}
										<p class="mt-0.5 text-xs text-ink-faint">
											{t('availability.by', { name: poll.created_by.display_name })}
										</p>
									{/if}
								</div>
								{#if poll.closed}
									<span
										class="shrink-0 rounded-full border border-line bg-paper px-2.5 py-0.5 text-xs text-ink-muted"
									>
										{poll.converted_event_id
											? t('availability.converted')
											: t('availability.closed')}
									</span>
								{/if}
							</div>

							<ul class="mt-3 flex flex-col divide-y divide-line">
								{#each poll.options as option (option.id)}
									{@const tally = tallyAnswers(option)}
									<li class="py-3">
										<div class="flex flex-wrap items-center justify-between gap-2">
											<p class="text-sm font-medium text-ink">
												{formatDate(option.starts_at, i18n.locale)}
												<span class="ml-1 text-ink-faint"
													>{formatDateTime(option.starts_at, i18n.locale)}</span
												>
											</p>
											<p class="text-xs text-ink-muted">
												{t('availability.tally', {
													yes: String(tally.yes),
													if_needed: String(tally.if_needed),
													no: String(tally.no)
												})}
											</p>
										</div>

										{#if !poll.closed && poll.viewer_can.includes('respond')}
											<div
												class="mt-2 flex overflow-hidden rounded-lg border border-line"
												role="group"
												aria-label={t('availability.answer.label', {
													date: formatDate(option.starts_at, i18n.locale)
												})}
											>
												{#each answers as value (value)}
													<button
														type="button"
														disabled={busy.includes(`${poll.id}:${option.id}`)}
														aria-pressed={option.my_answer === value}
														onclick={() => answer(poll, option.id, value)}
														class="flex-1 px-3 py-1.5 text-xs transition-colors duration-150 disabled:opacity-50 {option.my_answer ===
														value
															? 'bg-accent/10 font-medium text-accent'
															: 'text-ink-muted hover:bg-ink/5'}"
													>
														{t(`availability.answer.${value}`)}
													</button>
												{/each}
											</div>
										{/if}

										{#if !poll.closed && poll.viewer_can.includes('manage')}
											<div class="mt-2">
												<Button
													variant="ghost"
													size="sm"
													disabled={busy.includes(poll.id)}
													onclick={() => convert(poll, option.id)}
												>
													{t('availability.convert')}
												</Button>
											</div>
										{/if}
									</li>
								{/each}
							</ul>

							{#if !poll.closed && poll.viewer_can.includes('manage')}
								<div class="mt-2">
									<Button
										variant="secondary"
										size="sm"
										disabled={busy.includes(poll.id)}
										onclick={() => close(poll)}
									>
										{t('availability.close')}
									</Button>
								</div>
							{/if}
						</Card>
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
{/if}
