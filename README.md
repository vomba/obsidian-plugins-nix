# nixpille-obsidian-community-plugins

Obsidian community plugins packaged as Nix derivations for use with the
home-manager `programs.obsidian` module.

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
    excalidraw
  ];
```

## Adding a plugin

Edit `plugins.nix` and add an entry. Hashes come from GitHub release assets:

```sh
nix-prefetch-url https://github.com/<owner>/<repo>/releases/download/<version>/main.js
nix-prefetch-url https://github.com/<owner>/<repo>/releases/download/<version>/manifest.json
nix-prefetch-url https://github.com/<owner>/<repo>/releases/download/<version>/styles.css
nix hash convert --hash-algo sha256 --to sri <hash>
```

```nix
{
  my-plugin = {
    owner = "github-user";
    repo = "obsidian-my-plugin";
    version = "1.0.0";
    mainHash = "sha256-...";
    manifestHash = "sha256-...";
    stylesHash = "sha256-..."; # omit if the plugin has no styles.css
  };
}
```

## Available plugins

| Name | Plugin | Version |
|------|--------|---------|
| `excalidraw` | [obsidian-excalidraw-plugin](https://github.com/zsviczian/obsidian-excalidraw-plugin) | 2.20.3 |
