# ADR 0020: Custom profile fields — visibility lives outside `Kammer.Authorization`

## Context

SPEC §4: community admins can define custom profile fields ("Instrument",
"Section", "Dietary needs"), each with admin-set visibility (members /
admins-only) and an optional `required` flag — required fields hard-block at
join, but making an existing field required must never lock out someone who
already joined, only nag them. The member directory becomes filterable by
these fields: the band roster.

Every other visibility decision in Kammer — group access, post/comment
reach, file trees — flows through the single choke-point
`Kammer.Authorization`, with property-based tests over the permission
matrix. Custom field visibility is a much smaller thing: it decides whether
one line of text renders next to a name in a list. It carries no access
control weight (misreading it never exposes a group, a file, or a private
conversation — at worst, a member sees another member's dietary needs one
render too early because a role changed mid-session).

## Decision

Custom field (and personal contact field) visibility is a plain two-argument
predicate — `visibility_level, viewer_community_role -> boolean` — living
next to the data it gates (`Kammer.Communities.custom_field_visible?/2`,
`Kammer.Accounts.contact_visible?/2`), not routed through
`Kammer.Authorization`. The viewer's role comes from
`Authorization.relationship/2` (the same source of truth every other check
uses), so the _input_ is still centrally computed — only the redaction rule
itself is local and simple enough not to need its own property suite.

Three visibility levels exist across two contexts:

- **Custom fields** (community-defined): `members` / `admins` — an admin
  wouldn't define a field with no audience, so there's no `hidden` option.
- **Personal contact fields** (phone, public email, other): `hidden` /
  `members` / `admins`, default `hidden` — these are the member's own data,
  so "don't show this to anyone" has to be expressible and is the default.

**Required fields never lock anyone out post-join.**
`missing_required_custom_fields/2` is the single function both paths read:
the invite-redemption flow (`InviteController.accept/2` and
`InviteLive.Show`) uses it to hard-block onto a small
`CommunityLive.CompleteProfile` page before finishing the join; every other
page (`CommunityLive.Home`) uses the exact same function to render a nag
banner with a link to the same page, never a redirect-away. An admin making
an existing field required changes nothing about who's already a member —
it only starts appearing in that one shared query.

## Consequences

- Two small, independently testable predicates instead of one generic rule
  bolted onto `Kammer.Authorization` (which already encodes group/file/post
  semantics that have nothing to do with "should this text show in a
  list") — kept out of that module deliberately, not by oversight.
- The member directory (`CommunityLive.Members`) does one batched query
  (`custom_field_values_by_user/2`) for all rows instead of one query per
  member, then redacts in memory — avoids N+1 without needing a database
  view or a denormalized visibility column.
- No property test suite for this feature, unlike the authorization matrix,
  sealed-group reduction, and file-visibility invariant — the visibility
  rule is two match clauses per context, covered by direct unit tests
  (`communities_custom_fields_test.exs`, `accounts_test.exs`). Revisit if
  the rule ever grows branches.
- `instance_name`, `community_creation_policy`, and `storage_policy` still
  have no post-setup edit UI; `/c/:slug/settings` gained its first
  "Member profile fields" admin section but doesn't yet expose those wizard-
  only instance fields.
