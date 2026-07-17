defmodule Kammer.Invitations do
  @moduledoc """
  Invite links (SPEC §3): per community and per group, with optional
  expiry, max-use count, and revocation. Email invites deliver the link to
  the invited address; redemption then requires signing in with that email.

  All permission decisions are delegated to `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias Kammer.Invitations.Invite
  alias Kammer.Invitations.InviteNotifier
  alias Kammer.RateLimit
  alias Kammer.Repo

  @doc """
  Creates a community-wide invite. Requires `:create_community_invite`.
  """
  @spec create_community_invite(User.t(), Community.t(), map()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def create_community_invite(%User{} = actor, %Community{} = community, attrs \\ %{}) do
    with :ok <- Authorization.authorize(actor, :create_community_invite, community) do
      insert_invite(actor, community, nil, attrs)
    end
  end

  @doc """
  Creates an invite into a specific group (joining also joins the
  community). Requires `:create_group_invite`.
  """
  @spec create_group_invite(User.t(), Group.t(), map()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def create_group_invite(%User{} = actor, %Group{} = group, attrs \\ %{}) do
    group = Repo.preload(group, :community)

    with :ok <- Authorization.authorize(actor, :create_group_invite, group) do
      insert_invite(actor, group.community, group, attrs)
    end
  end

  @doc """
  Lists an invite target's active (unrevoked) invites. Requires the same
  permission as creating them.
  """
  @spec list_invites(User.t(), Community.t() | Group.t()) ::
          {:ok, [Invite.t()]} | {:error, :unauthorized}
  def list_invites(%User{} = actor, %Community{} = community) do
    with :ok <- Authorization.authorize(actor, :create_community_invite, community) do
      {:ok,
       Repo.all(
         from(invite in Invite,
           where: invite.community_id == ^community.id and is_nil(invite.group_id),
           where: is_nil(invite.revoked_at),
           order_by: [desc: invite.inserted_at]
         )
       )}
    end
  end

  def list_invites(%User{} = actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :create_group_invite, group) do
      {:ok,
       Repo.all(
         from(invite in Invite,
           where: invite.group_id == ^group.id and is_nil(invite.revoked_at),
           order_by: [desc: invite.inserted_at]
         )
       )}
    end
  end

  @doc """
  Revokes an invite. Requires the same permission as creating it.
  """
  @spec revoke_invite(User.t(), Invite.t()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def revoke_invite(%User{} = actor, %Invite{} = invite) do
    invite = Repo.preload(invite, [:community, :group])

    authorized? =
      case invite.group do
        nil -> Authorization.can?(actor, :create_community_invite, invite.community)
        %Group{} = group -> Authorization.can?(actor, :create_group_invite, group)
      end

    if authorized? do
      invite
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Fetches an invite by id with community and group preloaded, or
  `nil`. Invalid ids read as `nil`; callers own the authorization
  decision (`revoke_invite/2` re-checks).
  """
  @spec get_invite(String.t()) :: Invite.t() | nil
  def get_invite(invite_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(invite_id),
         %Invite{} = invite <- Repo.get(Invite, uuid) do
      Repo.preload(invite, [:community, :group])
    else
      _missing -> nil
    end
  end

  @doc """
  Looks up an invite by token with community and group preloaded, or `nil`.
  """
  @spec get_invite_by_token(String.t()) :: Invite.t() | nil
  def get_invite_by_token(token) when is_binary(token) do
    Invite
    |> Repo.get_by(token: token)
    |> case do
      nil -> nil
      invite -> Repo.preload(invite, [:community, :group])
    end
  end

  @doc """
  Redeems an invite for a signed-in user: joins the community (and the
  group, for group invites). Atomically consumes one use so a max-use
  invite can never be over-redeemed. Email-bound invites require the
  redeeming account's email to match.
  """
  @spec redeem_invite(User.t(), String.t()) ::
          {:ok, Invite.t()} | {:error, :invalid | :email_mismatch | term()}
  def redeem_invite(%User{} = user, token) when is_binary(token) do
    Repo.transact(fn ->
      now = DateTime.utc_now(:second)

      with %Invite{} = invite <- locked_invite(token),
           true <- Invite.redeemable?(invite, now) || :not_redeemable,
           true <- email_allowed?(invite, user) || :email_mismatch,
           {:ok, _membership} <- join_targets(invite, user),
           {:ok, invite} <- consume_use(invite) do
        {:ok, invite}
      else
        nil -> {:error, :invalid}
        :not_redeemable -> {:error, :invalid}
        :email_mismatch -> {:error, :email_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp locked_invite(token) do
    Repo.one(
      from(invite in Invite,
        where: invite.token == ^token,
        lock: "FOR UPDATE",
        preload: [:community, :group]
      )
    )
  end

  defp email_allowed?(%Invite{invited_email: nil}, _user), do: true

  defp email_allowed?(%Invite{invited_email: invited_email}, %User{email: email}) do
    String.downcase(invited_email) == String.downcase(email)
  end

  defp join_targets(%Invite{group: %Group{} = group}, user) do
    Groups.add_member(group, user)
  end

  defp join_targets(%Invite{community: %Community{} = community}, user) do
    Communities.add_member(community, user)
  end

  defp consume_use(%Invite{} = invite) do
    invite
    |> Ecto.Changeset.change(use_count: invite.use_count + 1)
    |> Repo.update()
  end

  defp insert_invite(actor, community, group, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "community_id" => community.id,
        "group_id" => group && group.id,
        "created_by_user_id" => actor.id
      })

    # Email invites are throttled per acting admin before anything is
    # written or sent (issue #97): a refused invite inserts no row and
    # delivers no mail, so the limit caps arbitrary-recipient email
    # flooding without leaving orphaned tokens behind. Link invites
    # (no `invited_email`) send nothing and are never limited.
    # Validation runs first (issue #305), so a malformed address is
    # refused without consuming any of that email budget.
    changeset = Invite.create_changeset(%Invite{}, attrs)

    with {:ok, changeset} <- validate_invite(changeset),
         :ok <- check_email_invite_rate(actor, changeset),
         {:ok, invite} <- Repo.insert(changeset) do
      maybe_deliver_email(invite, actor, community, group)
      {:ok, invite}
    end
  end

  defp validate_invite(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp validate_invite(changeset), do: {:error, %{changeset | action: :insert}}

  # Keyed off the cast field, not raw attrs: whitespace-only input casts
  # to nil (a link invite, no mail sent), so the email budget is consumed
  # exactly when a delivery will actually be attempted.
  defp check_email_invite_rate(actor, changeset) do
    case Ecto.Changeset.get_field(changeset, :invited_email) do
      nil ->
        :ok

      _email ->
        case RateLimit.hit_invite_issuance(actor.id) do
          {:allow, _count} -> :ok
          {:deny, _retry_after} -> {:error, :rate_limited}
        end
    end
  end

  defp maybe_deliver_email(%Invite{invited_email: nil}, _actor, _community, _group), do: :ok

  defp maybe_deliver_email(%Invite{} = invite, actor, community, group) do
    InviteNotifier.deliver_invite(invite, actor, community, group)
    :ok
  end
end
