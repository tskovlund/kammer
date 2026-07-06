defmodule Kammer.Guests do
  @moduledoc """
  Email-only guest identities (SPEC §2): creation, verification, the
  account-upgrade claim, and full erasure. Guests interact through
  signed, expiring links only — they hold no session and no password,
  and every record they create is reachable (and erasable) from their
  management links (SPEC §12).
  """

  import Ecto.Query

  alias Kammer.Accounts.User
  alias Kammer.Events.EventRsvp
  alias Kammer.Feed.Comment
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  @doc """
  Fetches or creates the identity for an email, updating the display
  name to the most recently provided one and stamping `verified_at`
  (callers invoke this only after a signed email link was followed).
  """
  @spec verify_identity(String.t(), String.t()) ::
          {:ok, GuestIdentity.t()} | {:error, Ecto.Changeset.t()}
  def verify_identity(email, display_name) do
    now = DateTime.utc_now(:second)

    changeset =
      %GuestIdentity{}
      |> GuestIdentity.changeset(%{email: email, display_name: display_name})
      |> Ecto.Changeset.put_change(:verified_at, now)

    Repo.insert(changeset,
      on_conflict: [set: [display_name: display_name, verified_at: now, updated_at: now]],
      conflict_target: :email,
      returning: true
    )
  end

  @doc """
  Fetches a guest identity by id.
  """
  @spec get_identity(Ecto.UUID.t()) :: GuestIdentity.t() | nil
  def get_identity(id), do: Repo.get(GuestIdentity, id)

  @doc """
  Claims a guest's history for a freshly authenticated account with the
  same email (SPEC §2: automatic upgrade). RSVPs move to the user —
  except where the user already RSVPed themselves, in which case the
  member RSVP wins — comments move to the user (keeping their approval
  state), and the guest identity disappears.
  """
  @spec claim_history(User.t()) :: :ok
  def claim_history(%User{} = user) do
    case Repo.get_by(GuestIdentity, email: user.email) do
      nil ->
        :ok

      %GuestIdentity{} = identity ->
        {:ok, :claimed} =
          Repo.transact(fn ->
            already_answered =
              from(rsvp in EventRsvp,
                where: rsvp.user_id == ^user.id,
                select: rsvp.event_id
              )

            from(rsvp in EventRsvp,
              where: rsvp.guest_identity_id == ^identity.id,
              where: rsvp.event_id not in subquery(already_answered)
            )
            |> Repo.update_all(set: [user_id: user.id, guest_identity_id: nil])

            from(comment in Comment, where: comment.guest_identity_id == ^identity.id)
            |> Repo.update_all(set: [author_user_id: user.id, guest_identity_id: nil])

            # Remaining guest RSVPs are duplicates of member ones; the
            # identity delete cascades them away.
            Repo.delete!(identity)
            {:ok, :claimed}
          end)

        :ok
    end
  end

  @doc """
  Everything behind a guest's management link (SPEC §12): the identity,
  their RSVPs (events preloaded), and their comments (posts and groups
  preloaded) — the full inventory the manage page lists and the erasure
  removes.
  """
  @spec fetch_manage_state(String.t()) ::
          {:ok, %{identity: GuestIdentity.t(), rsvps: [EventRsvp.t()], comments: [Comment.t()]}}
          | {:error, :invalid}
  def fetch_manage_state(manage_token) do
    with {:ok, %{identity_id: identity_id}} <- Kammer.Guests.Token.verify_manage(manage_token),
         %GuestIdentity{} = identity <- get_identity(identity_id) do
      rsvps =
        Repo.all(
          from(rsvp in EventRsvp,
            where: rsvp.guest_identity_id == ^identity.id,
            preload: :event,
            order_by: [asc: rsvp.inserted_at]
          )
        )

      comments =
        Repo.all(
          from(comment in Comment,
            where: comment.guest_identity_id == ^identity.id,
            preload: [post: :group],
            order_by: [desc: comment.inserted_at]
          )
        )

      {:ok, %{identity: identity, rsvps: rsvps, comments: comments}}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  @doc """
  Erases a guest entirely (SPEC §12): the identity row and, by cascade,
  every record it authored.
  """
  @spec erase(GuestIdentity.t()) :: :ok
  def erase(%GuestIdentity{} = identity) do
    Repo.delete!(identity)
    :ok
  end

  @doc """
  Erases a guest through their signed management link.
  """
  @spec erase_by_token(String.t()) :: :ok | {:error, :invalid}
  def erase_by_token(manage_token) do
    with {:ok, %{identity: identity}} <- fetch_manage_state(manage_token) do
      erase(identity)
    end
  end
end
