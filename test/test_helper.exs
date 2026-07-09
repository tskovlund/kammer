ExUnit.start()

# The instance-settings singleton is lazily inserted on first access.
# Two concurrent sandboxed transactions racing that unique-index insert
# can deadlock (Postgres 40P01, issue #215) — production is safe (the
# insert is an idempotent upsert), but sandbox transactions never
# commit, so the speculative locks can cycle. Seed the row once,
# committed, before the sandbox takes over: the lazy path never fires.
Kammer.Repo.insert!(%Kammer.Communities.InstanceSettings{},
  on_conflict: :nothing,
  conflict_target: :singleton_guard
)

Ecto.Adapters.SQL.Sandbox.mode(Kammer.Repo, :manual)
