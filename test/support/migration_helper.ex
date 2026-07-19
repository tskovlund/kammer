defmodule Kammer.MigrationHelper do
  @moduledoc """
  Runs a data migration's `up/0` (or `down/0`) under the SQL sandbox, so
  a migration test can seed rows, run the *real* migration code — not a
  copy of its SQL — and assert on the result, all inside the test's own
  sandboxed transaction (first used by #308).

  Mechanics: `Ecto.Migration.Runner` collects the migration's `execute/1`
  commands into an Agent, and `flush/0` runs them in the *calling*
  process — this one — so they use the connection the sandbox already
  checked out for the test.

  Scope: explicit `up/0`/`down/0` migrations doing DML only. It is not
  meant for DDL (the sandbox transaction can't always run it) nor for
  `change/0`-only migrations (those need Ecto's `:backward` auto-reversal
  machinery, which this bypasses by calling the operation directly), and
  it takes no `prefix`.

  We drive the Runner with `start_link`/`stop` rather than the usual
  `start_supervised!/1`: the Runner is an unnamed Agent that a process
  finds through its own process dictionary (set by `metadata/2`), and
  `flush/0` must run in *this* process on its sandboxed connection — so
  it has to be started and stopped here, mirroring Ecto's own
  `Runner.run/8`. `start_link` links it to the test process, so it is
  reaped when the test ends, and the `after` below stops it even if the
  migration raises.
  """

  alias Ecto.Migration.Runner

  @doc """
  Runs `direction` (`:up` by default) of `module` against `Kammer.Repo`
  on the current process's sandboxed connection.
  """
  @spec run_migration(module(), :up | :down) :: :ok
  def run_migration(module, direction \\ :up) do
    repo = Kammer.Repo

    {:ok, runner} =
      Runner.start_link(
        {self(), repo, repo.config(), module, :forward, direction, %{level: false, sql: false}}
      )

    Runner.metadata(runner, [])

    try do
      apply(module, direction, [])
      Runner.flush()
    after
      Runner.stop()
    end

    :ok
  end
end
