{
  description = "Obsidian community plugins packaged for NixOS/home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

      inherit (nixpkgs) lib;

      forAllSystems = lib.genAttrs supportedSystems;

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

      mkPlugins = pkgs: lib.mapAttrs (_name: def: mkPlugin pkgs def) (import ./plugins.nix);
    in
    rec {
      lib = { inherit mkPlugin; };

      overlays.default = _: pkgs: {
        obsidianPlugins = packages.${pkgs.stdenv.hostPlatform.system};
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        mkPlugins pkgs
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              go
              gh
              jq
              nix
              nixfmt
            ];
          };
        }
      );
    };
}
