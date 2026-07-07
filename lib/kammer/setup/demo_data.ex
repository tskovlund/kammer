defmodule Kammer.Setup.DemoData do
  @moduledoc """
  Optional demo content created from the setup wizard (SPEC §13): a small
  demo community with a welcome group, example posts, a poll, and an
  event, so a fresh instance is explorable immediately. The demo
  community is tracked on the instance settings row and can be purged
  with one click by an instance operator.

  Content goes through the ordinary contexts (never raw inserts), so the
  demo exercises the same code paths as real usage.
  """

  use Gettext, backend: KammerWeb.Gettext

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Groups
  alias Kammer.Repo

  @demo_slug "demo"

  @doc """
  Creates the demo community for the operator. Idempotent: if a demo
  community is already tracked, it is returned unchanged.
  """
  @spec create(User.t()) :: {:ok, Community.t()} | {:error, term()}
  def create(%User{} = operator) do
    settings = Communities.get_instance_settings()

    case settings.demo_community_id do
      nil -> build(operator, settings)
      community_id -> {:ok, Repo.get!(Community, community_id)}
    end
  end

  @doc """
  Deletes the demo community and everything in it. Instance operators
  only. The tracking reference is cleared by the database (`nilify_all`).
  """
  @spec purge(User.t()) :: {:ok, Community.t()} | {:error, :unauthorized | :no_demo_community}
  def purge(%User{} = actor) do
    if Authorization.instance_operator?(actor) do
      settings = Communities.get_instance_settings()

      case settings.demo_community_id do
        nil ->
          {:error, :no_demo_community}

        community_id ->
          case Repo.delete(Repo.get!(Community, community_id)) do
            {:ok, community} -> {:ok, community}
            {:error, _changeset} -> {:error, :no_demo_community}
          end
      end
    else
      {:error, :unauthorized}
    end
  end

  defp build(operator, settings) do
    locale = settings.default_locale || "en"

    Gettext.with_locale(KammerWeb.Gettext, locale, fn ->
      with {:ok, community} <- create_demo_community(operator),
           {:ok, group} <- create_welcome_group(operator, community),
           {:ok, _welcome} <- Feed.create_post(operator, group, welcome_post_attrs()),
           {:ok, _poll} <- Feed.create_post(operator, group, poll_post_attrs()),
           {:ok, _event} <- Events.create_event(operator, group, event_attrs()),
           {:ok, _settings} <- track(settings, community) do
        {:ok, community}
      end
    end)
  end

  defp create_demo_community(operator) do
    Communities.create_community(operator, %{
      "name" => gettext("Demo community"),
      "slug" => available_slug(),
      "description" =>
        gettext("A safe place to click around. Delete it any time from the instance start page."),
      "accent_color" => "#B85C38"
    })
  end

  defp create_welcome_group(operator, community) do
    Groups.create_group(operator, community, %{
      "name" => gettext("Welcome"),
      "slug" => "welcome",
      "description" => gettext("Say hello and try things out — nothing here is precious.")
    })
  end

  defp welcome_post_attrs do
    %{
      "body_markdown" =>
        gettext("""
        ## Welcome to Kammer 👋

        This demo community exists so you can try things without consequences. A few ideas:

        - Write a **post** — Markdown works, including lists and `code`.
        - React to this post and leave a comment below.
        - Open the **Events** tab and RSVP to the demo event.
        - Check **Files** for the shared file space every group gets.

        When you're done exploring, an instance operator can remove this whole community with one click on the start page.
        """)
    }
  end

  defp poll_post_attrs do
    %{
      "body_markdown" => gettext("Polls work too. What should the next gathering be?"),
      "poll" => %{
        "multiple_choice" => true,
        "options" => [
          %{"text" => gettext("Board game night"), "position" => 0},
          %{"text" => gettext("Communal dinner"), "position" => 1},
          %{"text" => gettext("Hike and a picnic"), "position" => 2}
        ]
      }
    }
  end

  defp event_attrs do
    starts_at =
      DateTime.utc_now(:second)
      |> DateTime.add(7, :day)

    %{
      "title" => gettext("Demo gathering"),
      "description" => gettext("An example event — RSVP to see how attendance works."),
      "location" => gettext("The common room"),
      "starts_at" => starts_at,
      "ends_at" => DateTime.add(starts_at, 2, :hour)
    }
  end

  defp track(settings, community) do
    settings
    |> Ecto.Changeset.change(demo_community_id: community.id)
    |> Repo.update()
  end

  defp available_slug do
    if Communities.get_community_by_slug(@demo_slug) do
      @demo_slug <>
        "-" <> Base.encode32(:crypto.strong_rand_bytes(3), case: :lower, padding: false)
    else
      @demo_slug
    end
  end
end
