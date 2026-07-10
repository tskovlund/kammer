defmodule Kammer.ConfigTest do
  @moduledoc """
  Tier-2 deployment config (ADR 0027, issue #234): `parse_bounded_env_int!/3`
  is the shared boot-validation helper `config/runtime.exs` calls for
  every tier-2 numeric var (the #98 pattern — mirrors
  `KammerWeb.ClientIp.validate_config!/0`), and the accessors read
  back whatever `config/runtime.exs` stored, falling back to the
  compiled-in default when unset.
  """

  # async: false — mutates OS env vars and global application env.
  use ExUnit.Case, async: false

  alias Kammer.Config

  describe "parse_bounded_env_int!/3" do
    test "an unset var returns nil so the caller leaves the app-env key unset" do
      refute Config.parse_bounded_env_int!("KAMMER_TEST_UNSET_VAR", 1, 100)
    end

    test "a valid value in range is parsed" do
      System.put_env("KAMMER_TEST_BOUNDED_VAR", "42")
      on_exit(fn -> System.delete_env("KAMMER_TEST_BOUNDED_VAR") end)

      assert Config.parse_bounded_env_int!("KAMMER_TEST_BOUNDED_VAR", 1, 100) == 42
    end

    test "a non-integer value raises naming the var and the bad value" do
      System.put_env("KAMMER_TEST_BOUNDED_VAR", "not-a-number")
      on_exit(fn -> System.delete_env("KAMMER_TEST_BOUNDED_VAR") end)

      assert_raise ArgumentError, ~r/KAMMER_TEST_BOUNDED_VAR.*not-a-number/s, fn ->
        Config.parse_bounded_env_int!("KAMMER_TEST_BOUNDED_VAR", 1, 100)
      end
    end

    test "an out-of-bounds value raises naming the var and the configured bounds" do
      System.put_env("KAMMER_TEST_BOUNDED_VAR", "101")
      on_exit(fn -> System.delete_env("KAMMER_TEST_BOUNDED_VAR") end)

      assert_raise ArgumentError, ~r/KAMMER_TEST_BOUNDED_VAR.*between 1 and 100/, fn ->
        Config.parse_bounded_env_int!("KAMMER_TEST_BOUNDED_VAR", 1, 100)
      end
    end
  end

  describe "accessors fall back to their compiled-in default" do
    test "rate_limit_posts_per_5min/0 defaults to 10 when unset" do
      assert Config.rate_limit_posts_per_5min() == 10
    end

    test "content_retention_days/0 defaults to 30 when unset" do
      assert Config.content_retention_days() == 30
    end
  end

  describe "accessors honor an app-env override (as config/runtime.exs would set)" do
    test "rate_limit_posts_per_5min/0 reflects an overridden app-env value" do
      previous = Application.fetch_env(:kammer, :rate_limit_posts_per_5min)
      Application.put_env(:kammer, :rate_limit_posts_per_5min, 25)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kammer, :rate_limit_posts_per_5min, value)
          :error -> Application.delete_env(:kammer, :rate_limit_posts_per_5min)
        end
      end)

      assert Config.rate_limit_posts_per_5min() == 25
    end
  end
end
