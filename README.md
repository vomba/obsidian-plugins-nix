# nixpille-obsidian-community-plugins

All 2700+ [Obsidian community plugins](https://obsidian.md/plugins) packaged as
Nix derivations, auto-updated daily from the official plugin registry.

Plugin names use the canonical IDs from the
[community-plugins.json](https://github.com/obsidianmd/obsidian-releases/blob/master/community-plugins.json)
registry (e.g. `obsidian-git`, `obsidian-excalidraw-plugin`).

## Usage

Add as a flake input:

```nix
obsidian-plugins = {
  url = "github:cjavad/nixpille-obsidian-community-plugins";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Apply the overlay:

```nix
overlays = [ inputs.obsidian-plugins.overlays.default ];
```

Then use plugins via `pkgs.obsidianPlugins`:

```nix
programs.obsidian.vaults."Documents/notes".settings.communityPlugins =
  with pkgs.obsidianPlugins; [
    obsidian-excalidraw-plugin
    obsidian-git
    nldates-obsidian
  ];
```

Or build directly:

```sh
nix build github:cjavad/nixpille-obsidian-community-plugins#obsidian-git
```

## How it works

Each plugin is a fixed-output derivation that fetches `main.js`,
`manifest.json`, and optionally `styles.css` from the GitHub release.
One SRI hash covers the entire output directory.

```nix
# plugins.nix entry
obsidian-git = {
  owner = "Vinzent03";
  repo = "obsidian-git";
  version = "2.36.1";
  hash = "sha256-8dzlfkMG1xBJbpZDTlVYxXrtsCm8Sa9I+nvsXyT1K3Q=";
};
```

## Auto-update

A daily GitHub Action (`scripts/update-plugins.sh`) fetches the full community
plugin list, checks each for new releases, and updates `plugins.nix`
automatically. No manual hash wrangling needed.

Run locally:

```sh
# Update all plugins
bash scripts/update-plugins.sh

# Process a batch (for initial population or rate-limit-friendly runs)
MAX_PLUGINS=500 bash scripts/update-plugins.sh
```
