defmodule KammerWeb.Api.NewsletterTest do
  @moduledoc """
  Guest newsletter subscriptions over the API (issue #185, SPEC §8):
  the subscribe → confirm signed-link flow, and cadence/unsubscribe
  management through the shared guest management token. An invalid
  confirm token gets one neutral answer.

  Since issue #230 (ADR 0026) the management token rides an
  `Authorization: Bearer` header, not the URL — see `bearer_conn/1`.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers, only: [bearer_conn: 1]
  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions

  setup do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    drain_emails()
    %{community: community, group: group}
  end

  test "subscribe, confirm, change cadence, unsubscribe", %{community: community, group: group} do
    token =
      public_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/newsletter", %{
        "email" => "reader@example.org",
        "display_name" => "Reader",
        "cadence" => "weekly"
      })
      |> tap(&assert json_response(&1, 202))
      |> tap(&assert_operation_response(&1, "newsletter_subscribe"))
      |> token_from_email(~r{/newsletter/confirm/([^\s"<]+)})

    manage_token =
      public_conn()
      |> post(~p"/api/v1/newsletter/confirm", %{"token" => token})
      |> tap(&assert_operation_response(&1, "newsletter_confirm"))
      |> tap(fn conn ->
        assert %{"data" => %{"guest_name" => nil, "redirect_path" => path}} =
                 json_response(conn, 200)

        assert path =~ "/g/#{group.slug}"
      end)
      |> token_from_email(~r{/guest/manage#([^\s"<]+)})

    body = bearer_conn(manage_token) |> get(~p"/api/v1/guest/manage") |> json_response(200)
    assert [%{"cadence" => "weekly", "subscription_id" => id}] = body["data"]["subscriptions"]

    changed =
      bearer_conn(manage_token)
      |> put(~p"/api/v1/guest/manage/subscriptions/#{id}", %{"cadence" => "daily"})
      |> tap(&assert_operation_response(&1, "guest_set_cadence"))
      |> json_response(200)

    assert [%{"cadence" => "daily"}] = changed["data"]["subscriptions"]

    emptied =
      bearer_conn(manage_token)
      |> delete(~p"/api/v1/guest/manage/subscriptions/#{id}")
      |> tap(&assert_operation_response(&1, "guest_unsubscribe"))
      |> json_response(200)

    assert emptied["data"]["subscriptions"] == []
  end

  test "an invalid confirm token is one neutral answer" do
    assert %{"error" => %{"code" => "not_found"}} =
             public_conn()
             |> post(~p"/api/v1/newsletter/confirm", %{"token" => "not-a-token"})
             |> json_response(404)
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")

  # The management token's transport since ADR 0026: an Authorization
  # header, not a URL segment.

  defp token_from_email(_conn, regex) do
    assert_email_sent(fn email ->
      [captured] = Regex.run(regex, email.text_body, capture: :all_but_first)
      send(self(), {:extracted_token, captured})
      true
    end)

    assert_received {:extracted_token, token}
    token
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end
end
