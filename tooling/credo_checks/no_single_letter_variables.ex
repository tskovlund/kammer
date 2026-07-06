defmodule Kammer.CredoChecks.NoSingleLetterVariables do
  @moduledoc """
  Custom Credo check enforcing the project naming rule from SPEC §17:
  full, descriptive, unabbreviated identifiers — single-letter variable
  names are banned (`_` and `_`-prefixed ignored bindings are allowed).

  Compiled only in dev/test via `elixirc_paths` (Credo is not a runtime
  dependency).
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Single-letter variable names hide meaning. Use full, descriptive
      identifiers (SPEC §17, CONVENTIONS.md): `post`, not `p`;
      `community` not `c` — including in Ecto queries and comprehensions.
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
    |> Enum.uniq_by(fn issue -> {issue.line_no, issue.trigger} end)
  end

  defp traverse({variable_name, meta, context} = ast, issues, issue_meta)
       when is_atom(variable_name) and is_atom(context) and not is_nil(context) do
    name_string = Atom.to_string(variable_name)

    if single_letter?(name_string) do
      {ast, [issue_for(issue_meta, meta[:line], name_string) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp single_letter?(name_string) do
    String.length(name_string) == 1 and not String.starts_with?(name_string, "_")
  end

  defp issue_for(issue_meta, line_number, variable_name) do
    format_issue(
      issue_meta,
      message:
        "Single-letter variable `#{variable_name}` is banned; " <>
          "use a full, descriptive name (SPEC §17).",
      trigger: variable_name,
      line_no: line_number
    )
  end
end
