{
  description = "Obsidian community plugins packaged for NixOS/home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkPlugin =
        pkgs:
        {
          owner,
          repo,
          version,
          mainHash,
          manifestHash,
          stylesHash ? null,
          meta ? { },
        }:
        let
          baseUrl = "https://github.com/${owner}/${repo}/releases/download/${version}";
        in
        pkgs.stdenv.mkDerivation {
          pname = repo;
          inherit version;

          srcs =
            [
              (pkgs.fetchurl {
                url = "${baseUrl}/main.js";
                hash = mainHash;
              })
              (pkgs.fetchurl {
                url = "${baseUrl}/manifest.json";
                hash = manifestHash;
              })
            ]
            ++ pkgs.lib.optional (stylesHash != null) (pkgs.fetchurl {
              url = "${baseUrl}/styles.css";
              hash = stylesHash;
            });

          dontUnpack = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            for src in $srcs; do
              filename=$(stripHash "$src")
              cp "$src" "$out/$filename"
            done
            runHook postInstall
          '';

          inherit meta;
        };

      pluginDefs = import ./plugins.nix;

      mkPlugins =
        pkgs: builtins.mapAttrs (_name: def: mkPlugin pkgs def) pluginDefs;
    in
    {
      lib.mkPlugin = mkPlugin;

      overlays.default = _final: prev: {
        obsidianPlugins = mkPlugins prev;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        mkPlugins pkgs
      );
    };
}
