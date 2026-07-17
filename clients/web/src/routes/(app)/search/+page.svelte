<script lang="ts">
	import { resolve } from '$app/paths';
	import { fetchAuthedObjectUrl } from '$lib/feed/api.js';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { failureMessage } from '$lib/instances/failure-copy.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import type { Instance } from '$lib/instances/types.js';
	import { createSearchStore } from '$lib/tools/search-store.svelte.js';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const store = createSearchStore();
	let queryInput = $state('');

	const multiInstance = $derived(instances.several);

	// Debounced fanout: a new query settles for 300ms before searching every
	// account, so keystrokes don't each trigger a round of requests. The store's
	// own generation guard drops any that resolve out of order.
	$effect(() => {
		const query = queryInput;
		const list = instances.list;
		const handle = setTimeout(() => void store.run(list, query), 300);
		return () => clearTimeout(handle);
	});

	$effect(() => () => store.stop());

	function submit(event: SubmitEvent) {
		event.preventDefault();
		void store.run(instances.list, queryInput);
	}

	async function download(instance: Instance, path: string, filename: string): Promise<void> {
		try {
			const objectUrl = await fetchAuthedObjectUrl(instance, path);
			const anchor = document.createElement('a');
			anchor.href = objectUrl;
			anchor.download = filename;
			anchor.rel = 'noopener';
			document.body.appendChild(anchor);
			anchor.click();
			anchor.remove();
			URL.revokeObjectURL(objectUrl);
		} catch {
			/* a failed download stays silent — the list is unaffected */
		}
	}
</script>

<svelte:head><title>{t('search.title')} · {t('app.name')}</title></svelte:head>

<h1 class="text-xl font-semibold tracking-tight text-ink">{t('search.title')}</h1>

<form class="mt-4" onsubmit={submit} role="search">
	<label for="search-input" class="sr-only">{t('search.label')}</label>
	<input
		id="search-input"
		type="search"
		bind:value={queryInput}
		placeholder={t('search.placeholder')}
		autocomplete="off"
		class="h-11 w-full rounded-lg border border-line bg-surface px-3 text-base text-ink transition-colors duration-150 placeholder:text-ink-faint hover:border-ink-faint/60 focus:border-accent focus:outline-none"
	/>
</form>

<div class="mt-6">
	{#if store.loadState === 'idle'}
		<EmptyState title={t('search.idle.title')} body={t('search.idle.body')} />
	{:else if store.loadState === 'loading'}
		<div class="flex flex-col gap-3">
			<Skeleton class="h-24" />
			<Skeleton class="h-24" />
		</div>
	{:else if store.loadState === 'error'}
		<EmptyState title={t('search.error.title')} body={t('search.error.body')} />
	{:else if store.isEmpty}
		<EmptyState
			title={t('search.empty.title')}
			body={t('search.empty.body', { query: store.query })}
		/>
	{:else}
		{#each store.failedInstances as failed (failed.instance.id)}
			<p class="mb-3 rounded-lg border border-line bg-paper px-3 py-2 text-sm text-ink-muted">
				{failureMessage(failed)}
			</p>
		{/each}

		<div class="flex flex-col gap-8">
			{#each store.buckets as bucket (bucket.id)}
				<section aria-labelledby="bucket-{bucket.id}">
					<h2 id="bucket-{bucket.id}" class="mb-3 text-sm font-semibold text-ink">
						{bucket.community.name}
						{#if multiInstance}
							<span class="font-normal text-ink-faint">· {bucket.instance.instanceName}</span>
						{/if}
					</h2>

					<div class="flex flex-col gap-4">
						{#if bucket.results.posts.length > 0}
							<div>
								<h3 class="mb-1.5 text-xs font-medium tracking-wide text-ink-faint uppercase">
									{t('search.section.posts')}
								</h3>
								<Card class="divide-y divide-line">
									{#each bucket.results.posts as post (post.id)}
										{@const slug = bucket.groupSlugById[post.group_id]}
										<div class="px-4 py-3">
											{#if slug}
												<a
													href={resolve(
														`/i/${bucket.instance.id}/c/${bucket.community.slug}/g/${slug}`
													)}
													class="block hover:opacity-80"
												>
													{#if post.body_markdown}
														<Markdown
															source={post.body_markdown}
															inline
															class="line-clamp-2 text-sm"
														/>
													{:else}
														<span class="text-sm text-ink-muted">{t('search.untitledPost')}</span>
													{/if}
												</a>
											{:else if post.body_markdown}
												<Markdown source={post.body_markdown} inline class="line-clamp-2 text-sm" />
											{:else}
												<span class="text-sm text-ink-muted">{t('search.untitledPost')}</span>
											{/if}
										</div>
									{/each}
								</Card>
							</div>
						{/if}

						{#if bucket.results.comments.length > 0}
							<div>
								<h3 class="mb-1.5 text-xs font-medium tracking-wide text-ink-faint uppercase">
									{t('search.section.comments')}
								</h3>
								<Card class="divide-y divide-line">
									{#each bucket.results.comments as comment (comment.id)}
										<div class="px-4 py-3">
											{#if comment.deleted || !comment.body_markdown}
												<span class="text-sm text-ink-faint">{t('search.deletedComment')}</span>
											{:else}
												<Markdown
													source={comment.body_markdown}
													inline
													class="line-clamp-2 text-sm"
												/>
											{/if}
										</div>
									{/each}
								</Card>
							</div>
						{/if}

						{#if bucket.results.events.length > 0}
							<div>
								<h3 class="mb-1.5 text-xs font-medium tracking-wide text-ink-faint uppercase">
									{t('search.section.events')}
								</h3>
								<Card class="divide-y divide-line">
									{#each bucket.results.events as event (event.id)}
										<a
											href={resolve(
												`/i/${bucket.instance.id}/c/${bucket.community.slug}/e/${event.id}`
											)}
											class="flex items-center justify-between gap-3 px-4 py-3 hover:bg-ink/2"
										>
											<span class="min-w-0 truncate text-sm font-medium text-ink"
												>{event.title}</span
											>
											<span class="shrink-0 text-xs text-ink-faint">
												{formatDate(event.starts_at, i18n.locale)}
											</span>
										</a>
									{/each}
								</Card>
							</div>
						{/if}

						{#if bucket.results.files.length > 0}
							<div>
								<h3 class="mb-1.5 text-xs font-medium tracking-wide text-ink-faint uppercase">
									{t('search.section.files')}
								</h3>
								<Card class="divide-y divide-line">
									{#each bucket.results.files as file (file.id)}
										<div class="flex items-center justify-between gap-3 px-4 py-3">
											<span class="min-w-0 truncate text-sm font-medium text-ink"
												>{file.filename}</span
											>
											<button
												type="button"
												class="shrink-0 text-sm text-accent hover:underline"
												onclick={() => download(bucket.instance, file.download_url, file.filename)}
											>
												{t('search.download')}
											</button>
										</div>
									{/each}
								</Card>
							</div>
						{/if}
					</div>
				</section>
			{/each}
		</div>
	{/if}
</div>
