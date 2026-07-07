# Credo configuration (SPEC §17: strict mode, naming, complexity,
# single-letter-variable ban, doc requirements).
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "config/",
          "priv/repo/",
          "tooling/credo_checks/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/", ~r"/.nix-mix/", ~r"/.nix-hex/"]
      },
      requires: ["tooling/credo_checks/no_single_letter_variables.ex"],
      checks: %{
        enabled: [
          # Project-specific naming rule (SPEC §17).
          {Kammer.CredoChecks.NoSingleLetterVariables, []},

          # Doc requirements: every module documented. Migrations are DDL
          # scripts, not API surface.
          {Credo.Check.Readability.ModuleDoc, files: %{excluded: ["priv/repo/migrations/"]}},

          # @spec on every public function (SPEC §17). Structs/behaviour
          # callbacks are covered by their own typespecs; migration up/down
          # are framework entry points.
          {Credo.Check.Readability.Specs,
           include_defp: false, files: %{excluded: ["priv/repo/migrations/", "test/"]}}
        ],
        disabled: [
          # Deferred work is tracked in an issue or docs/HANDOFF.md's
          # backlog; TODO comments must reference one, so the tag itself
          # is not an issue.
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
