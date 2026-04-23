package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	registryURL = "https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/community-plugins.json"
	maxJobs     = 20
	batchSize   = 100
)

type RegistryPlugin struct {
	ID   string `json:"id"`
	Repo string `json:"repo"`
}

type NixPlugin struct {
	Owner   string `json:"owner"`
	Repo    string `json:"repo"`
	Version string `json:"version"`
	Tag     string `json:"tag,omitempty"`
	Hash    string `json:"hash"`
}

func main() {
	startTime := time.Now()
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		out, err := exec.Command("gh", "auth", "token").Output()
		if err == nil {
			token = strings.TrimSpace(string(out))
		}
	}

	// 1. Fetch Registry
	log.Println("==> Fetching community-plugins.json")
	registry, err := fetchRegistry()
	if err != nil {
		log.Fatalf("Failed to fetch registry: %v", err)
	}
	log.Printf("  %d community plugins\n", len(registry))

	// 2. Load Cache
	log.Println("==> Loading cache from plugins.nix")
	cache, err := loadCache()
	if err != nil {
		log.Printf("  Warning: could not load cache: %v (starting fresh)\n", err)
		cache = make(map[string]NixPlugin)
	}
	log.Printf("  %d cached\n", len(cache))

	// 3. Fetch Latest Tags (GraphQL)
	log.Println("==> Fetching latest tags from GitHub")
	tags := fetchLatestTags(registry, token)

	// 4. Identify Updates
	var work []RegistryPlugin
	results := make(map[string]NixPlugin)
	var skipped int

	for _, p := range registry {
		tag, ok := tags[p.ID]
		if !ok || tag == "" {
			continue
		}
		version := strings.TrimPrefix(tag, "v")

		cached, exists := cache[p.ID]
		if exists && cached.Version == version {
			results[p.ID] = cached
			skipped++
			continue
		}
		work = append(work, p)
	}
	log.Printf("  %d up to date, %d to hash\n", skipped, len(work))

	// 5. Hash Updates (Parallel)
	if len(work) > 0 {
		log.Printf("==> Hashing %d plugins using %d workers\n", len(work), maxJobs)
		mu := sync.Mutex{}
		wg := sync.WaitGroup{}
		semaphore := make(chan struct{}, maxJobs)

		for i, p := range work {
			wg.Add(1)
			go func(idx int, plugin RegistryPlugin) {
				defer wg.Done()
				semaphore <- struct{}{}
				defer func() { <-semaphore }()

				tag := tags[plugin.ID]
				version := strings.TrimPrefix(tag, "v")
				parts := strings.Split(plugin.Repo, "/")
				owner, repo := parts[0], parts[1]

				hash, err := computeNixHash(owner, repo, tag)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					log.Printf("  [%d/%d] FAILED %s: %v (keeping old version)\n", idx+1, len(work), plugin.ID, err)
					if old, exists := cache[plugin.ID]; exists {
						results[plugin.ID] = old
					}
				} else {
					log.Printf("  [%d/%d] Updated %s to %s\n", idx+1, len(work), plugin.ID, version)
					np := NixPlugin{
						Owner:   owner,
						Repo:    repo,
						Version: version,
						Hash:    hash,
					}
					if tag != version {
						np.Tag = tag
					}
					results[plugin.ID] = np
				}
			}(i, p)
		}
		wg.Wait()
	}

	// 6. Render
	log.Println("==> Rendering plugins.nix")
	if err := renderNix(results); err != nil {
		log.Fatalf("Failed to render output: %v", err)
	}

	log.Printf("=== Done in %v ===\n", time.Since(startTime).Round(time.Second))
}

func fetchRegistry() ([]RegistryPlugin, error) {
	resp, err := http.Get(registryURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var plugins []RegistryPlugin
	err = json.NewDecoder(resp.Body).Decode(&plugins)
	return plugins, err
}

func loadCache() (map[string]NixPlugin, error) {
	if _, err := os.Stat("plugins.nix"); os.IsNotExist(err) {
		return nil, err
	}
	cmd := exec.Command("nix", "eval", "--json", "--file", "plugins.nix")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var cache map[string]NixPlugin
	err = json.Unmarshal(out, &cache)
	return cache, err
}

func fetchLatestTags(registry []RegistryPlugin, token string) map[string]string {
	tags := make(map[string]string)
	mu := sync.Mutex{}
	wg := sync.WaitGroup{}

	for i := 0; i < len(registry); i += batchSize {
		end := i + batchSize
		if end > len(registry) {
			end = len(registry)
		}
		batch := registry[i:end]
		wg.Add(1)

		go func(b []RegistryPlugin, offset int) {
			defer wg.Done()

			var query strings.Builder
			query.WriteString("{ ")
			for j, p := range b {
				parts := strings.Split(p.Repo, "/")
				query.WriteString(fmt.Sprintf(`r%d: repository(owner: "%s", name: "%s") { latestRelease { tagName } } `, offset+j, parts[0], parts[1]))
			}
			query.WriteString("}")

			input := struct {
				Query string `json:"query"`
			}{Query: query.String()}

			payload, _ := json.Marshal(input)
			req, _ := http.NewRequest("POST", "https://api.github.com/graphql", bytes.NewBuffer(payload))
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return
			}
			defer resp.Body.Close()

			var result struct {
				Data map[string]struct {
					LatestRelease struct {
						TagName string `json:"tagName"`
					} `json:"latestRelease"`
				} `json:"data"`
			}
			json.NewDecoder(resp.Body).Decode(&result)

			mu.Lock()
			for j, p := range b {
				if r, ok := result.Data[fmt.Sprintf("r%d", offset+j)]; ok {
					tags[p.ID] = r.LatestRelease.TagName
				}
			}
			mu.Unlock()
		}(batch, i)
	}
	wg.Wait()
	return tags
}

func computeNixHash(owner, repo, tag string) (string, error) {
	tmp, err := os.MkdirTemp("", "obsidian-plugin-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)

	baseURL := fmt.Sprintf("https://github.com/%s/%s/releases/download/%s", owner, repo, tag)
	files := []string{"main.js", "manifest.json", "styles.css"}

	wg := sync.WaitGroup{}
	for _, f := range files {
		wg.Add(1)
		go func(filename string) {
			defer wg.Done()
			resp, err := http.Get(baseURL + "/" + filename)
			if err != nil || resp.StatusCode != 200 {
				return
			}
			defer resp.Body.Close()
			out, _ := os.Create(filepath.Join(tmp, filename))
			defer out.Close()
			_, _ = io.Copy(out, resp.Body)
		}(f)
	}
	wg.Wait()

	if _, err := os.Stat(filepath.Join(tmp, "main.js")); err != nil {
		return "", fmt.Errorf("missing main.js (assets might not be released yet)")
	}

	cmd := exec.Command("nix", "hash", "path", tmp)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func renderNix(plugins map[string]NixPlugin) error {
	var keys []string
	for k := range plugins {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	f, err := os.Create("plugins.nix")
	if err != nil {
		return err
	}
	defer f.Close()

	fmt.Fprintln(f, "# Auto-generated by Go updater from obsidianmd/obsidian-releases")
	fmt.Fprintln(f, "# Do not edit manually — changes will be overwritten on next update.")
	fmt.Fprintln(f, "{")
	for _, k := range keys {
		p := plugins[k]
		safeID := k
		if !isSafe(k) {
			safeID = "\"" + k + "\""
		}
		fmt.Fprintf(f, "  %s = {\n", safeID)
		fmt.Fprintf(f, "    owner = \"%s\";\n", p.Owner)
		fmt.Fprintf(f, "    repo = \"%s\";\n", p.Repo)
		fmt.Fprintf(f, "    version = \"%s\";\n", p.Version)
		if p.Tag != "" {
			fmt.Fprintf(f, "    tag = \"%s\";\n", p.Tag)
		}
		fmt.Fprintf(f, "    hash = \"%s\";\n", p.Hash)
		fmt.Fprintf(f, "  };\n")
	}
	fmt.Fprintln(f, "}")
	return nil
}

func isSafe(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		if i == 0 && !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_') {
			return false
		}
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-') {
			return false
		}
	}
	return true
}
