defmodule KammerWeb.Api.GroupGate do
  @moduledoc """
  The shared "resolve a slug-addressed group" gate every group
  sub-endpoint controller opens with (issue #339): a missing
  community, a missing group slug, and a group the actor may not even
  *view* all fold into the same neutral 404 — an unviewable
  private/sealed group must be indistinguishable from a nonexistent
  one to a slug-guessing prober. Pass `feature: :atom` to additionally
  fold a disabled feature toggle (ADR 0016) into the same 404 — a
  group without the tool is unreachable either way, so there's nothing
  for the caller to distinguish.

  `group_controller.ex` made exactly this fold on the group endpoint
  itself (#224); eight private `with_group`/`with_feature_group`/
  `with_files_group` copies across the post, event, calendar,
  assignment, availability, decision, file-library, and group-member
  controllers didn't, and were dismissed as "established pattern" —
  the dismissal #339 revisits. A review pass over that fix caught four
  more of the same oracle — uploads, group invites, the anonymous
  newsletter subscribe, and anonymous guest comments — and a second,
  independent pass caught the last one on the event-addressed twin
  (the anonymous guest-RSVP/guest-claim surfaces). Since #345 the
  anonymous surfaces resolve through `Groups.fetch_public_group/2` /
  `Events.fetch_public_event/2` instead of this gate — the stricter
  publicly-readable fold — so this gate's callers are the
  authenticated slug-addressed controllers. It is the one shared
  fetch for them; each controller still wraps it in its own thin
  `with_group` so the callback shape (community and/or user in scope,
  alongside group) stays whatever that controller's call sites
  already expect — the fetch was the duplicated, bug-prone part, not
  the callback shape.

  Contract for those thin wrappers: a wrapper that matches only
  `{:ok, ...}` / `{:error, :not_found}` (post, event, calendar,
  file-library, group, guest) commits its callback to *always* return
  a rendered `%Plug.Conn{}` — an error tuple escaping such a callback
  is a 500, the exact bug #339 fixed in the feature controllers.
  A wrapper whose callbacks can return error tuples must thread
  `%Plug.Conn{} = responded <-` and route the else through
  `ApiError.from_result` (assignment, availability, decision,
  group-member, invite). When adding an action, match the wrapper's
  shape — or upgrade the wrapper, never the callback alone.

  Only the `:view_group` (and feature-gate) resolution folds to 404
  here. A group the actor *can* see but isn't allowed to write to,
  join, or manage still gets an honest 403 from the write check inside
  the caller's own callback, once existence is no longer in question.
  """

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Groups
  alias Kammer.Groups.Group

  @doc """
  Resolves `community_slug`/`group_slug` to `{:ok, community, group}`
  for `actor`, or `{:error, :not_found}` — folding a missing
  community, a missing group, a group `actor` may not view, and (with
  `feature: :atom`) a group with that feature off into the one
  answer.
  """
  @spec fetch(User.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, Community.t(), Group.t()} | {:error, :not_found}
  def fetch(actor, community_slug, group_slug, opts \\ []) do
    with %Community{} = community <- Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(actor, community, group_slug),
         :ok <- feature_gate(group, opts[:feature]) do
      {:ok, community, group}
    else
      # The three folded denials, spelled out — anything else is a new
      # return shape and must crash loudly here rather than silently
      # read as 404.
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :not_found}
    end
  end

  defp feature_gate(_group, nil), do: :ok
  defp feature_gate(group, feature), do: Authorization.feature_gate(group, feature)
end
