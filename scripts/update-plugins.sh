#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS_FILE="$REPO_ROOT/plugins.nix"

for cmd in gh jq nix curl; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }
done

log() { echo "$@" >&2; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

COMMUNITY_FILE="$WORK_DIR/community.json"
CACHE_FILE="$WORK_DIR/cache.json"
TAGS_FILE="$WORK_DIR/tags.jsonl"
UPDATES_FILE="$WORK_DIR/updates.jsonl"
RESULT_FILE="$WORK_DIR/result.json"

touch "$TAGS_FILE" "$UPDATES_FILE"

compute_hash() {
  local base_url="$1" tmpdir
  tmpdir=$(mktemp -d)
  curl -sfL -o "$tmpdir/main.js" "$base_url/main.js" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  curl -sfL -o "$tmpdir/manifest.json" "$base_url/manifest.json" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  curl -sfL -o "$tmpdir/styles.css" "$base_url/styles.css" 2>/dev/null || true
  nix hash path "$tmpdir" 2>/dev/null
  rm -rf "$tmpdir"
}

gh_graphql() {
  local attempt
  for attempt in 1 2 3; do
    if gh api graphql "$@" 2>/dev/null; then return 0; fi
    log "    retrying in 60s (attempt $attempt/3)..."
    sleep 60
  done
  return 1
}

# ========== Phase 1: Fetch inputs ==========
log "==> Fetching community-plugins.json"
gh api repos/obsidianmd/obsidian-releases/contents/community-plugins.json \
  -H "Accept: application/vnd.github.raw" 2>/dev/null > "$COMMUNITY_FILE"
plugin_count=$(jq 'length' "$COMMUNITY_FILE")
log "  $plugin_count community plugins"

log "==> Loading cache"
if [[ -f "$PLUGINS_FILE" ]]; then
  nix eval --json --file "$PLUGINS_FILE" 2>/dev/null > "$CACHE_FILE" || echo "{}" > "$CACHE_FILE"
else
  echo "{}" > "$CACHE_FILE"
fi
log "  $(jq 'length' "$CACHE_FILE") cached"

# ========== Phase 2: Batch GraphQL for latest tags ==========
total_batches=$(( (plugin_count + 99) / 100 ))
log ""
log "==> Fetching tags ($total_batches GraphQL calls)"

for (( batch_start=0; batch_start < plugin_count; batch_start += 100 )); do
  batch_end=$(( batch_start + 99 ))
  (( batch_end >= plugin_count )) && batch_end=$(( plugin_count - 1 ))
  batch_num=$(( batch_start / 100 + 1 ))

  log "  [$batch_num/$total_batches] plugins $((batch_start+1))-$((batch_end+1))"

  query=$(jq -r --argjson s "$batch_start" --argjson e "$batch_end" '
    . as $list |
    [range($s; $e + 1)] |
    map(
      . as $i | $list[$i].repo | split("/") as $p |
      "r\($i): repository(owner: \"\($p[0])\", name: \"\($p[1])\") { latestRelease { tagName } }"
    ) | "{ " + join(" ") + " }"
  ' "$COMMUNITY_FILE")

  if ! gh_graphql -f query="$query" > "$WORK_DIR/batch.json"; then
    log "    batch failed, skipping"
    for (( i=batch_start; i <= batch_end; i++ )); do
      jq -n -c --arg id "$(jq -r ".[$i].id" "$COMMUNITY_FILE")" '{($id): null}' >> "$TAGS_FILE"
    done
    continue
  fi

  jq -c --slurpfile community "$COMMUNITY_FILE" --argjson s "$batch_start" --argjson e "$batch_end" '
    .data as $d |
    [range($s; $e + 1)] | map(
      . as $i | { ($community[0][$i].id): ($d["r\($i)"].latestRelease.tagName // null) }
    )[]
  ' "$WORK_DIR/batch.json" >> "$TAGS_FILE"
done

log "  Merging tags..."
jq -s 'reduce .[] as $x ({}; . * $x)' "$TAGS_FILE" > "$WORK_DIR/tags.json"

# ========== Phase 3: Diff against cache ==========
log ""
log "==> Diffing against cache"

# Bulk carry forward all up-to-date entries from cache (single jq pass)
jq -c --slurpfile tags "$WORK_DIR/tags.json" '
  $tags[0] as $tags |
  to_entries[] |
  select($tags[.key] != null and .value.version == ($tags[.key] | ltrimstr("v"))) |
  {(.key): .value}
' "$CACHE_FILE" >> "$UPDATES_FILE"
skipped=$(wc -l < "$UPDATES_FILE")

# Generate TSV of plugins that need hashing (single jq pass, zero per-plugin jq calls)
jq -r --slurpfile tags "$WORK_DIR/tags.json" --slurpfile cache "$CACHE_FILE" '
  $tags[0] as $tags |
  $cache[0] as $cache |
  .[] |
  .id as $id |
  .repo | split("/") as $p |
  ($tags[$id] // null) as $tag |
  select($tag != null) |
  ($tag | ltrimstr("v")) as $ver |
  select($ver != ($cache[$id].version // "")) |
  [$id, $p[0], $p[1], $tag, $ver] | @tsv
' "$COMMUNITY_FILE" > "$WORK_DIR/to_hash.tsv"

to_hash=$(wc -l < "$WORK_DIR/to_hash.tsv")
log "  $skipped up to date, $to_hash to hash"

# ========== Phase 4: Hash changed plugins ==========
if (( to_hash > 0 )); then
  log ""
  log "==> Hashing $to_hash plugins"
fi

added=0
failed=0
n=0

while IFS=$'\t' read -r plugin_id owner repo tag_name clean_version; do
  ((n++)) || true
  log "  [$n/$to_hash] $plugin_id"

  base_url="https://github.com/$owner/$repo/releases/download/$tag_name"
  if ! hash=$(compute_hash "$base_url"); then
    log "    FAILED (missing assets)"
    ((failed++)) || true
    continue
  fi

  jq -n -c \
    --arg id "$plugin_id" \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --arg version "$clean_version" \
    --arg tag "$tag_name" \
    --arg hash "$hash" \
    '{($id): ({owner: $owner, repo: $repo, version: $version, hash: $hash} + (if $tag != $version then {tag: $tag} else {} end))}' >> "$UPDATES_FILE"
  ((added++)) || true
done < "$WORK_DIR/to_hash.tsv"

# ========== Phase 5: Render ==========
log ""
log "==> Rendering plugins.nix"

jq -s 'reduce .[] as $x ({}; . * $x)' "$UPDATES_FILE" > "$RESULT_FILE"

jq -r '
  "# Auto-generated by scripts/update-plugins.sh from obsidianmd/obsidian-releases",
  "# Do not edit manually — changes will be overwritten on next update.",
  "{",
  (to_entries | sort_by(.key)[] |
    "  " + (if (.key | test("^[a-zA-Z_][a-zA-Z0-9_-]*$")) then .key else ("\"" + .key + "\"") end) + " = {",
    ("    owner = \"" + .value.owner + "\";"),
    ("    repo = \"" + .value.repo + "\";"),
    ("    version = \"" + .value.version + "\";"),
    (if .value.tag then "    tag = \"" + .value.tag + "\";" else empty end),
    ("    hash = \"" + .value.hash + "\";"),
    "  };"
  ),
  "}"
' "$RESULT_FILE" > "$WORK_DIR/plugins.nix"

mv "$WORK_DIR/plugins.nix" "$PLUGINS_FILE"

no_release=$(( plugin_count - skipped - added - failed ))
log ""
log "=== Done ==="
log "  API calls:  $((total_batches + 1)) (1 REST + $total_batches GraphQL)"
log "  Plugins:    $plugin_count total"
log "  Skipped:    $skipped (up to date)"
log "  Added:      $added"
log "  Failed:     $failed"
log "  No release: $no_release"
