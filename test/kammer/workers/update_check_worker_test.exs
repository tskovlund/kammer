defmodule Kammer.Workers.UpdateCheckWorkerTest do
  @moduledoc """
  Worker-level coverage for the daily update-notice tick (SPEC §13):
  that `perform/1` actually delegates to `Kammer.UpdateCheck.run/0`.
  Kept to the disabled branch so the test never makes a real network
  request — the enabled fetch/parse/record behavior is covered in
  depth by `Kammer.UpdateCheckTest`.
  """

  use Kammer.DataCase, async: false
  use Oban.Testing, repo: Kammer.Repo

  alias Kammer.Workers.UpdateCheckWorker

  setup do
    original = Application.get_env(:kammer, :update_check)

    on_exit(fn ->
      if original do
        Application.put_env(:kammer, :update_check, original)
      else
        Application.delete_env(:kammer, :update_check)
      end
    end)

    :ok
  end

  test "delegates to UpdateCheck.run/0" do
    Application.put_env(:kammer, :update_check, enabled: false)

    assert :ok = perform_job(UpdateCheckWorker, %{})
  end
end
