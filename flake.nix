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
          tag ? version,
          hash,
          meta ? { },
        }:
        let
          baseUrl = "https://github.com/${owner}/${repo}/releases/download/${tag}";
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = repo;
          inherit version;

          outputHash = hash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";

          nativeBuildInputs = [ pkgs.curl ];
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          phases = [ "installPhase" ];
          installPhase = ''
            mkdir -p $out
            curl -sfL -o $out/main.js "${baseUrl}/main.js"
            curl -sfL -o $out/manifest.json "${baseUrl}/manifest.json"
            curl -sfL -o $out/styles.css "${baseUrl}/styles.css" 2>/dev/null || true
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
