defmodule Kammer.UpdateCheckTest do
  @moduledoc """
  The admin update notice (SPEC §13): opt-out gate, version
  comparison, and recording a check result on the singleton instance
  settings row.
  """

  use Kammer.DataCase, async: false

  alias Kammer.Communities
  alias Kammer.UpdateCheck

  setup do
    original = Application.get_env(:kammer, :update_check)

    on_exit(fn ->
      if original do
        Application.put_env(:kammer, :update_check, original)
      else
        Application.delete_env(:kammer, :update_check)
      end
    end)
  end

  describe "enabled?/0" do
    test "defaults to enabled when unconfigured" do
      Application.delete_env(:kammer, :update_check)
      assert UpdateCheck.enabled?()
    end

    test "respects an explicit opt-out" do
      Application.put_env(:kammer, :update_check, enabled: false)
      refute UpdateCheck.enabled?()
    end
  end

  describe "update_available?/1" do
    test "false when no check has run yet" do
      settings = %Communities.InstanceSettings{latest_known_version: nil}
      refute UpdateCheck.update_available?(settings)
    end

    test "true when the recorded version is newer" do
      newer = bump_patch(Kammer.version())
      settings = %Communities.InstanceSettings{latest_known_version: newer}
      assert UpdateCheck.update_available?(settings)
    end

    test "false when the recorded version is the same or older" do
      settings = %Communities.InstanceSettings{
        latest_known_version: Kammer.version()
      }

      refute UpdateCheck.update_available?(settings)
    end

    test "false for an unparseable recorded version, rather than raising" do
      settings = %Communities.InstanceSettings{latest_known_version: "not-a-version"}
      refute UpdateCheck.update_available?(settings)
    end

    defp bump_patch(version) do
      %Version{major: major, minor: minor, patch: patch} = Version.parse!(version)
      "#{major}.#{minor}.#{patch + 1}"
    end
  end

  describe "run/1" do
    test "records the latest release on success" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"tag_name" => "v99.0.0", "html_url" => "https://example.com/v99"})
      end)

      assert :ok = UpdateCheck.run(plug: {Req.Test, __MODULE__})

      settings = Communities.get_instance_settings()
      assert settings.latest_known_version == "99.0.0"
      assert settings.latest_known_release_url == "https://example.com/v99"
      assert settings.update_checked_at
    end

    test "does nothing when disabled — no request, no recorded change" do
      Application.put_env(:kammer, :update_check, enabled: false)

      assert :ok = UpdateCheck.run(plug: {Req.Test, __MODULE__})

      settings = Communities.get_instance_settings()
      assert settings.latest_known_version == nil
    end

    test "a failed fetch is not an error and leaves settings unchanged" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert :ok = UpdateCheck.run(plug: {Req.Test, __MODULE__}, retry: false)

      settings = Communities.get_instance_settings()
      assert settings.latest_known_version == nil
    end
  end
end
