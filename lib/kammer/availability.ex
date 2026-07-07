defmodule Kammer.Availability do
  @moduledoc """
  Date-finding polls (issue #39, collaborative track #17): propose
  candidate dates, members answer yes / if needed / no per date, and
  closing the poll can convert the winning date into a real event.

  Feature-gated per group (`:availability`, OFF by default). All
  permission decisions delegate to `Kammer.Authorization`: creating a
  poll follows the group's posting policy, answering follows the same
  rule as RSVPs, closing and converting is for the poll's creator and
  group moderators.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Availability.AvailabilityOption
  alias Kammer.Availability.AvailabilityPoll
  alias Kammer.Availability.AvailabilityResponse
  alias Kammer.Communities.Community
  alias Kammer.Events
  alias Kammer.Groups.Group
  alias Kammer.Repo

  @doc """
  Creates a poll with its candidate dates (at least one required).
  """
  @spec create_poll(User.t(), Group.t(), map(), [DateTime.t()]) ::
          {:ok, AvailabilityPoll.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :not_found | :no_options}
  def create_poll(%User{} = creator, %Group{} = group, attrs, option_starts) do
    with :ok <- Authorization.feature_gate(group, :availability),
         :ok <- Authorization.authorize(creator, :post_in_group, group),
         true <- option_starts != [] or {:error, :no_options} do
      Repo.transact(fn ->
        with {:ok, poll} <-
               %AvailabilityPoll{
                 community_id: group.community_id,
                 group_id: group.id,
                 created_by_user_id: creator.id
               }
               |> AvailabilityPoll.changeset(attrs)
               |> Repo.insert() do
          option_starts
          |> Enum.sort(DateTime)
          |> Enum.with_index()
          |> Enum.each(fn {starts_at, index} ->
            Repo.insert!(
              AvailabilityOption.changeset(%AvailabilityOption{poll_id: poll.id}, %{
                starts_at: starts_at,
                position: index
              })
            )
          end)

          {:ok, get_poll!(poll.id)}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches a poll the actor may see (view on the host group + feature
  gate), with options, responses, and responders preloaded.
  """
  @spec fetch_viewable_poll(User.t() | nil, Ecto.UUID.t()) ::
          {:ok, AvailabilityPoll.t(), Group.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_poll(actor, poll_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(poll_id),
         %AvailabilityPoll{} = poll <- Repo.get(AvailabilityPoll, poll_id),
         %Group{} = group <- Repo.get(Group, poll.group_id),
         :ok <- Authorization.feature_gate(group, :availability),
         :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok, get_poll!(poll.id), group}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _missing_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Open polls across the groups the actor can see in the community
  (feature-gated per group), oldest first — the ones waiting for
  answers, listed on the events page.
  """
  @spec list_open_polls(User.t() | nil, Community.t()) :: [AvailabilityPoll.t()]
  def list_open_polls(actor, %Community{} = community) do
    group_ids =
      actor
      |> Authorization.listable_groups_query(community)
      |> where([group], fragment("'availability' = ANY(?)", group.features))
      |> select([group], group.id)
      |> Repo.all()

    Repo.all(
      from(poll in AvailabilityPoll,
        where: poll.group_id in ^group_ids and is_nil(poll.closed_at),
        order_by: [asc: poll.inserted_at],
        preload: [:group, options: ^options_query()]
      )
    )
  end

  @doc """
  Sets the actor's answer for one candidate date (upsert — answering
  again replaces). Follows the same rule as RSVPs; closed polls refuse.
  """
  @spec respond(User.t(), AvailabilityOption.t(), AvailabilityResponse.answer()) ::
          {:ok, AvailabilityResponse.t()} | {:error, :unauthorized | :closed}
  def respond(%User{} = actor, %AvailabilityOption{} = option, answer)
      when answer in [:yes, :if_needed, :no] do
    poll = Repo.get!(AvailabilityPoll, option.poll_id)
    group = Repo.get!(Group, poll.group_id)
    relationship = Authorization.relationship(actor, group)

    cond do
      AvailabilityPoll.closed?(poll) ->
        {:error, :closed}

      not Authorization.can_react?(actor, group, relationship) ->
        {:error, :unauthorized}

      true ->
        %AvailabilityResponse{}
        |> AvailabilityResponse.changeset(%{
          answer: answer,
          option_id: option.id,
          user_id: actor.id
        })
        |> Repo.insert(
          on_conflict: [set: [answer: answer, updated_at: DateTime.utc_now(:second)]],
          conflict_target: [:option_id, :user_id],
          returning: true
        )
    end
  end

  @doc """
  Whether the actor may close or convert the poll — its creator or a
  group moderator.
  """
  @spec can_manage_poll?(User.t() | nil, AvailabilityPoll.t(), Group.t()) :: boolean()
  def can_manage_poll?(actor, %AvailabilityPoll{} = poll, %Group{} = group) do
    Authorization.can_manage_own_resource?(actor, poll.created_by_user_id, group)
  end

  @doc """
  Closes the poll by converting the chosen date into a real event
  (poll title carried over; the event fan-out notifies as usual).
  """
  @spec convert_to_event(User.t(), AvailabilityPoll.t(), AvailabilityOption.t()) ::
          {:ok, AvailabilityPoll.t(), Kammer.Events.Event.t()}
          | {:error, :unauthorized | :closed | term()}
  def convert_to_event(
        %User{} = actor,
        %AvailabilityPoll{} = poll,
        %AvailabilityOption{} = option
      ) do
    group = Repo.get!(Group, poll.group_id)

    cond do
      option.poll_id != poll.id ->
        {:error, :unauthorized}

      AvailabilityPoll.closed?(poll) ->
        {:error, :closed}

      not can_manage_poll?(actor, poll, group) ->
        {:error, :unauthorized}

      true ->
        Repo.transact(fn ->
          with {:ok, event} <-
                 Events.create_event(actor, group, %{
                   "title" => poll.title,
                   "starts_at" => option.starts_at
                 }),
               {:ok, closed_poll} <-
                 poll
                 |> Ecto.Changeset.change(
                   closed_at: DateTime.utc_now(:second),
                   converted_event_id: event.id
                 )
                 |> Repo.update() do
            {:ok, {closed_poll, event}}
          end
        end)
        |> case do
          {:ok, {closed_poll, event}} -> {:ok, closed_poll, event}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Closes the poll without converting (it didn't work out).
  """
  @spec close_poll(User.t(), AvailabilityPoll.t()) ::
          {:ok, AvailabilityPoll.t()} | {:error, :unauthorized | :closed}
  def close_poll(%User{} = actor, %AvailabilityPoll{} = poll) do
    group = Repo.get!(Group, poll.group_id)

    cond do
      AvailabilityPoll.closed?(poll) ->
        {:error, :closed}

      not can_manage_poll?(actor, poll, group) ->
        {:error, :unauthorized}

      true ->
        poll
        |> Ecto.Changeset.change(closed_at: DateTime.utc_now(:second))
        |> Repo.update()
    end
  end

  defp get_poll!(poll_id) do
    Repo.one!(
      from(poll in AvailabilityPoll,
        where: poll.id == ^poll_id,
        preload: [:created_by_user, options: ^{options_query(), [responses: :user]}]
      )
    )
  end

  defp options_query do
    from(option in AvailabilityOption, order_by: [asc: option.position, asc: option.starts_at])
  end
end
