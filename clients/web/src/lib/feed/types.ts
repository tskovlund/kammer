import type { components } from '$lib/api/schema.js';

/** Convenience aliases for the feed's wire shapes (KammerWeb.Api.Serializer). */
export type Post = components['schemas']['Post'];
export type Comment = components['schemas']['Comment'];
export type Poll = NonNullable<components['schemas']['Poll']>;
export type PollOption = Poll['options'][number];
export type Attachment = components['schemas']['Attachment'];
export type Author = components['schemas']['Author'];
export type StoredFile = components['schemas']['StoredFile'];
export type Notification = components['schemas']['Notification'];
export type Community = components['schemas']['Community'];

/** How the feed is ordered (SPEC §5): strict chronological, or forum-style bump. */
export type FeedSort = 'chronological' | 'activity';
