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

      mkTheme =
        pkgs:
        {
          src,

          subDir ? ".",
          extraFiles ? [ ],

          meta,
        }:
        pkgs.runCommand
          (lib.concatStringsSep "-" [
            src.name
            src.rev
          ])
          { inherit meta; }
          ''
            mkdir -p $out
            cp ${
              lib.concatStringsSep " " (
                map (file: "${src}/${subDir}/${file}") (
                  [
                    "manifest.json"
                    "theme.css"
                  ]
                  ++ extraFiles
                )
              )
            } $out/
          '';

      mkPlugins = pkgs: lib.mapAttrs (_name: def: mkPlugin pkgs def) (import ./plugins.nix);
    in
    rec {
      lib = { inherit mkPlugin mkTheme; };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        (mkPlugins pkgs)
        // {
          minimal = mkTheme pkgs {
            src = pkgs.fetchFromGitHub {
              owner = "kepano";
              repo = "obsidian-minimal";
              rev = "8.0.4";
              sha256 = "sha256-TGToK2k9zpd5LappqlkGgxJliXqE4HzsBq07c4IN+T4=";
            };

            meta = {
              description = "A distraction-free and highly customizable theme for Obsidian.";
              homepage = "https://github.com/kepano/obsidian-minimal";
              license = lib.licenses.mit;
            };
          };
        }
      );
    };
}
