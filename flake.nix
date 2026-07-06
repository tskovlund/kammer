{
  description = "Kammer — self-hosted community platform (dev environment)";

  inputs = {
    # Immutable pinned nixpkgs snapshot (nixpkgs-unstable channel release).
    # Pinned via URL + flake.lock narHash; equally reproducible as a
    # github: input and fetchable without GitHub API access.
    nixpkgs.url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1027958.c4013e501c04/nixexprs.tar.xz";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = generate: nixpkgs.lib.genAttrs systems (system: generate system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          beamPackages = pkgs.beam.packages.erlang_27;
          elixir = beamPackages.elixir_1_18;

          # Everything a contributor (and CI) needs for setup, run, test,
          # lint, and format. devbox.json mirrors this list for non-Nix users.
          devTools = [
            elixir
            beamPackages.erlang
            pkgs.nodejs_22
            pkgs.postgresql_16
            pkgs.vips
            pkgs.pkg-config
            pkgs.lefthook
            pkgs.git
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.inotify-tools
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.fswatch
          ];
        in
        {
          default = pkgs.mkShell {
            packages = devTools;

            shellHook = ''
              # Keep Mix/Hex state inside the project so the environment is
              # self-contained and removable.
              export MIX_HOME="$PWD/.nix-mix"
              export HEX_HOME="$PWD/.nix-hex"
              export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"
              export LANG=C.UTF-8
              export LC_ALL=C.UTF-8
              export ERL_AFLAGS="-kernel shell_history enabled"
            '';
          };
        });

      formatter = forAllSystems (system:
        (import nixpkgs { inherit system; }).nixpkgs-fmt);
    };
}
