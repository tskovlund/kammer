import type { components } from '$lib/api/schema.js';

/** Convenience aliases for the people rung's wire shapes (#182). */
export type Member = components['schemas']['Member'];
export type MemberUser = components['schemas']['MemberUser'];
export type CustomField = components['schemas']['CustomField'];
export type Invite = components['schemas']['Invite'];
export type Profile = components['schemas']['Profile'];
export type Device = components['schemas']['Device'];
export type Passkey = components['schemas']['Passkey'];
export type PasskeyRegistrationChallenge = components['schemas']['PasskeyRegistrationChallenge'];
export type NotificationLevel = components['schemas']['NotificationLevel'];

export type Role = Member['role'];
export type NotificationLevelValue = NotificationLevel['level'];
export type ContactVisibility = Profile['contact_phone_visibility'];
export type DigestFrequency = Profile['digest_frequency'];

/** The roster response: rows plus the viewer-visible field definitions. */
export interface Roster {
	members: Member[];
	fields: CustomField[];
}

/** The editable subset of the own-profile shape (PUT /me). */
export interface ProfileParams {
	display_name?: string;
	locale?: string;
	timezone?: string;
	digest_frequency?: DigestFrequency;
	bio?: string | null;
	pronouns?: string | null;
	contact_phone?: string | null;
	contact_phone_visibility?: ContactVisibility;
	contact_email?: string | null;
	contact_email_visibility?: ContactVisibility;
	contact_note?: string | null;
	contact_note_visibility?: ContactVisibility;
}
