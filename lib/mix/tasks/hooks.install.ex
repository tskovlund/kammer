defmodule Mix.Tasks.Hooks.Install do
  @shortdoc "Installs lefthook git hooks and commitlint tooling"

  @moduledoc """
  Installs the project's git hooks (SPEC §17).

  Runs `lefthook install` (lefthook is provided by the dev shell — Nix flake,
  devbox, or direnv) and installs the commitlint npm tooling used by the
  commit-msg hook. Invoked automatically as part of `mix setup`.
  """

  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    install_lefthook()
    install_commitlint()
    :ok
  end

  defp install_lefthook do
    case System.find_executable("lefthook") do
      nil ->
        Mix.shell().info(
          "lefthook not found on PATH — skipping hook install. " <>
            "Enter the dev shell (nix develop / devbox shell / direnv allow) and re-run mix setup."
        )

      _path ->
        {output, 0} = System.cmd("lefthook", ["install"], stderr_to_stdout: true)
        Mix.shell().info(String.trim(output))
    end
  end

  defp install_commitlint do
    case System.find_executable("npm") do
      nil ->
        Mix.shell().info("npm not found on PATH — skipping commitlint install.")

      _path ->
        {_output, status} =
          System.cmd("npm", ["install", "--no-audit", "--no-fund"],
            cd: Path.join(File.cwd!(), "tooling/commitlint"),
            stderr_to_stdout: true
          )

        if status == 0 do
          Mix.shell().info("commitlint tooling installed.")
        else
          Mix.shell().info(
            "commitlint npm install failed (offline?) — commit-msg hook will " <>
              "fall back to npx download on first use."
          )
        end
    end
  end
end
