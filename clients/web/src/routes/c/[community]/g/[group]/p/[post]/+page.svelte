<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import {
		fetchPublicGroup,
		fetchPublicPost,
		requestGuestComment,
		type Group
	} from '$lib/public/api.js';
	import type { Post } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import GuestRequestForm from '$lib/public/components/GuestRequestForm.svelte';
	import PublicAttachments from '$lib/public/components/PublicAttachments.svelte';
	import PublicCommentList from '$lib/public/components/PublicCommentList.svelte';

	// A single post, publicly readable (issue #185 slice B), hosting the
	// guest comment request form when the group opted in
	// (`guest_comment_allowed`, SPEC §3's `members_and_guests` comment
	// policy). The group is fetched alongside the post purely for that
	// flag — the post itself only carries its `group_id`, not the group's
	// guest settings.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let group = $state<Group | null>(null);
	let post = $state<Post | null>(null);
	let commentBody = $state('');

	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);
	const postId = $derived(page.params.post!);

	onMount(async () => {
		try {
			const [fetchedGroup, fetchedPost] = await Promise.all([
				fetchPublicGroup(window.location.origin, communitySlug, groupSlug),
				fetchPublicPost(window.location.origin, communitySlug, groupSlug, postId)
			]);
			group = fetchedGroup;
			post = fetchedPost;
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	async function submitComment(identity: { email: string; displayName: string }): Promise<void> {
		await requestGuestComment(
			window.location.origin,
			communitySlug,
			groupSlug,
			postId,
			identity,
			commentBody.trim()
		);
	}
</script>

<svelte:head><title>{t('public.post.loading')} · {t('app.name')}</title></svelte:head>

<PublicShell maxWidth="max-w-2xl">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('public.post.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-24 w-full" />
			</div>
		</div>
	{:else if loadState === 'error' || !post || !group}
		<EmptyState title={t('public.post.error.title')} body={t('public.post.error.body')} />
	{:else}
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a
			href={resolve(`/c/${communitySlug}/g/${groupSlug}`)}
			class="text-sm text-ink-muted underline decoration-line underline-offset-4 transition-colors duration-150 hover:text-ink"
		>
			← {group.name}
		</a>

		<Card class="mt-3 p-4 sm:p-5">
			<div class="flex items-start gap-3">
				<Avatar author={post.author} />
				<div class="min-w-0 flex-1">
					<div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
						<span class="font-medium text-ink">
							{post.author?.display_name ?? t('feed.author.unknown')}
						</span>
						<RelativeTime datetime={post.published_at} class="text-xs" />
						{#if post.edited_at}
							<span class="text-xs text-ink-faint">· {t('feed.edited')}</span>
						{/if}
					</div>
				</div>
			</div>

			{#if post.body_markdown}
				<Markdown source={post.body_markdown} class="mt-3 text-[0.95rem] text-ink" />
			{/if}

			{#if post.attachments.length > 0}
				<div class="mt-3">
					<PublicAttachments attachments={post.attachments} />
				</div>
			{/if}
		</Card>

		<section class="mt-8" aria-labelledby="public-post-comments-heading">
			<h2 id="public-post-comments-heading" class="text-sm font-semibold text-ink">
				{t('public.post.comments.title')}
			</h2>
			<div class="mt-3">
				<PublicCommentList
					comments={post.comments ?? []}
					emptyLabel={t('public.post.comments.empty')}
				/>
			</div>
		</section>

		{#if group.guest_comment_allowed}
			<section class="mt-8 border-t border-line pt-6">
				<h2 class="text-sm font-semibold text-ink">{t('public.post.commentForm.title')}</h2>
				<div class="mt-3">
					<GuestRequestForm
						idPrefix="public-post-comment"
						onSubmit={submitComment}
						submitLabel={t('public.post.commentForm.submit')}
						successTitle={t('public.post.commentForm.success.title')}
						successBody={t('public.post.commentForm.success.body')}
						disabled={commentBody.trim().length === 0}
					>
						{#snippet extra()}
							<div class="flex flex-col gap-1.5">
								<label for="public-post-comment-body" class="text-sm font-medium text-ink">
									{t('public.post.commentForm.body')}
								</label>
								<textarea
									id="public-post-comment-body"
									bind:value={commentBody}
									rows="3"
									class="w-full resize-y rounded-lg border border-line bg-surface px-3 py-2 text-sm text-ink transition-colors duration-150 placeholder:text-ink-faint hover:border-ink-faint/60 focus-visible:border-accent"
								></textarea>
							</div>
						{/snippet}
					</GuestRequestForm>
				</div>
			</section>
		{/if}
	{/if}
</PublicShell>
