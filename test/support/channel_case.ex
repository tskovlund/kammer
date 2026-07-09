defmodule KammerWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix Channel tests (`KammerWeb.Api.UserSocket` and
  its channels). Channel processes are spawned outside the test
  process, so channel tests run `async: false` — the shared SQL
  sandbox mode is what lets a spawned channel query the database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import KammerWeb.ChannelCase

      @endpoint KammerWeb.Endpoint
    end
  end

  setup tags do
    Kammer.DataCase.setup_sandbox(tags)
    :ok
  end
end
