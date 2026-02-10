# Obsidian community plugin definitions.
# Each key becomes a package name accessible via pkgs.obsidianPlugins.<name>
#
# To add a new plugin:
#   1. Find the GitHub release for the plugin
#   2. Run: nix-prefetch-url https://github.com/<owner>/<repo>/releases/download/<version>/<file>
#   3. Convert hash: nix hash convert --hash-algo sha256 --to sri <hash>
#   4. Add an entry below
{
  excalidraw = {
    owner = "zsviczian";
    repo = "obsidian-excalidraw-plugin";
    version = "2.20.3";
    mainHash = "sha256-Mo2Y5Up640ZW/gBjPaFKsYJ5woFSs+1hXJzwEaSVfYQ=";
    manifestHash = "sha256-klmPQ2toHZJBdrcn6U3YcvIierJcNyA3fYUT0zeD3+M=";
    stylesHash = "sha256-0kwMNFxq+QvWPxtDYqdSj+AieYSatqWwy8xAfVTdHlU=";
  };
}
