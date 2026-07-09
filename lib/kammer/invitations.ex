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
  alias Kammer.Repo

  @doc """
  Creates a community-wide invite. Requires `:create_community_invite`.
  """
  @spec create_community_invite(User.t(), Community.t(), map()) ::
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
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
          {:ok, Invite.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
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

    with {:ok, invite} <- %Invite{} |> Invite.create_changeset(attrs) |> Repo.insert() do
      maybe_deliver_email(invite, actor, community, group)
      {:ok, invite}
    end
  end

  defp maybe_deliver_email(%Invite{invited_email: nil}, _actor, _community, _group), do: :ok

  defp maybe_deliver_email(%Invite{} = invite, actor, community, group) do
    InviteNotifier.deliver_invite(invite, actor, community, group)
    :ok
  end

  @doc """
  Returns a changeset for invite forms.
  """
  @spec change_invite(Invite.t(), map()) :: Ecto.Changeset.t()
  def change_invite(%Invite{} = invite, attrs \\ %{}) do
    Invite.create_changeset(invite, attrs)
  end
end
