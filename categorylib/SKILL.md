---
name: categorylib
description: >-
  Prefer the categoryclient CLI (search, tree, get, GetCategoryByID, jq) to
  inspect Carousell listing categories without writing Go. Works with
  github.com/carousell/categorylib library: GCS/offline data, category.Init,
  GetCategory*, OfflineMode, metadata, collection groups, flags. Use when the
  user runs or mentions categoryclient, category exploration, jq on categories,
  or integrating or changing categorylib / category.Init / cmd/categoryclient.
---

# categorylib

Go library under `category/` for **country-scoped category trees** loaded from **Google Cloud Storage** (or **`offlinemode` embedded bytes**). Consumers import `github.com/carousell/categorylib/category`.

---

## Prefer CLI vs library

- **Exploration, one-off lookups, answering “what is category X”** — run **`categoryclient`** on `PATH` (e.g. after `go install github.com/carousell/categorylib/cmd/categoryclient@latest`). Do **not** spin up a throwaway Go `main` for that.
- **Shipping behavior in a service, tests in this repo, or changing loaders/APIs** — use the **`category`** package and the sections below (`Init`, maps, transforms).

When unsure of subcommands or flags, run **`categoryclient --help`** and subcommand help.

---

## `categoryclient` commands

Install: `go install github.com/carousell/categorylib/cmd/categoryclient@latest`.

The binary calls **`category.Init`** with **`UseFallback: false`** only — expect **network access to GCS** for CSV/flag fetches unless the tooling is changed.

| Command | Purpose |
|--------|---------|
| **`search`** | Interactive picker via **`fzf`** (`exec.Command("fzf")`). **Requires `fzf` on PATH**; poor fit for fully non-interactive agent runs. |
| **`tree <country_code>`** | Prints lines `id  CC  name` (e.g. SG, TW). Flags: **`--show-disabled`**, **`--leaf-only`**, **`--top-level-only`**. **Default for agents** when `search` is not viable. |
| **`get`** / **`GetCategoryByID <id>`** | One category as JSON. |
| **`GetCategoryByCountryIDAndLegacyID`** | Flags **`--country-id`**, **`--collection-id`** (legacy collection id). |

**Persistent flags** (root): **`--stage`** (staging GCS), **`--locale`** (e.g. `en`, `zh`, `id`), **`--show-subcats`** (include nested `subcategories` in JSON; **default omits** nested subcats).

**Examples** (prod data unless `--stage`):

```bash
categoryclient get 306 | jq '{id, name, country_id, legacy_id}'
categoryclient tree SG
categoryclient --stage tree SG
categoryclient --locale zh get 306 | jq .
categoryclient GetCategoryByCountryIDAndLegacyID --country-id 1668284 --collection-id 4 | jq .
```

---

## Initialization (required) — library use

1. Call **`category.Init(opts category.CategoryOpts)` exactly once** in process startup. **`Init` is idempotent** (later calls no-op).

2. **`CategoryOpts`** (`types.go`):
   - **`IsStaging`**: load `staging/` vs `production/` paths from the GCS bucket.
   - **`RefreshRateInMins`**: background refresh interval; **`0` means 10 minutes** (see `setup.go`).
   - **`UseFallback`**: if initial remote load fails, **`ErrorHandler` is invoked** then **`loadData(false, ...)`** runs (embedded CSVs/flags via `offlinemode`).
   - **`OfflineMode: true`**: never fetches remote; uses embedded data only; **no refresh goroutine**.
   - **`ErrorHandler`**: optional callback on load errors during fallback or periodic refresh.

3. **Before `Init`**, package-level maps are empty; **`GetCategoryByID` and peers return `NotFoundError`** until data is loaded.

---

## Data sources

- **Remote**: `category/utils.go` — `bucketRoot` + `production/` or `staging/` + filenames in `remotePaths` (CSVs + `country_collections_flagdata.json`).
- **Local / tests**: `offlinemode` varbytes wired in `localBytes`; regenerate via scripts in `category/scripts/` if those snapshots change.

---

## Public API surface (common)

| Area | Functions / types |
|------|-------------------|
| Lookup | `GetCategoryByID`, `GetCategoryByCountryIDAndLegacyID`, `GetCategoriesByCountryID` |
| Metadata | `GetCategoryMetadataByID`, `GetCategoryMetadataFilterSettingByMetadataID` |
| Tree | `GetParents`, `IsParent`, `IsSameBranch` |
| Verticals | `GetVerticalByCategoryID`, `IsVerticalCategory` (see `global.go` maps) |
| Collections UI | `GetCollectionGroups(countryCode, languageTag)` — falls back to **`"sg"`** if country unknown; localizes group **keys** when a match exists |
| SEO | `UpdateDefaultInterlinksForCategory` |
| Errors | **`category.NotFoundError`** — use **`errors.Is(err, category.NotFoundError)`** |

---

## Verticals by country (`global.go`)

Verticals are **not a field on the `Category` struct** — there is no `is_vertical` in the JSON output. They are defined as a hardcoded map in `category/global.go`: `verticalTopLevelCategoriesByCountryCode` (keyed by country ID) and the legacy `topLevelVerticals` map.

To look up verticals via CLI, resolve the IDs below with `categoryclient get <id>`.

| Country | Country ID | Vertical category IDs (top-level) |
|---------|------------|-----------------------------------|
| SG | 1880251 | 22 (Cars), 73 (Property), 1708 (Home Services), 2318 (Lifestyle Services), 1707 (Jobs) |
| HK | 1819730 | 124 (Cars), 125 (Property), 1758 (Services), 1774 (Jobs) |
| MY | 1733045 | 174 (Cars), 195 (Property), 1828 (Services), 1841 (Jobs) |
| PH | 1694008 | 144 (Cars), 166 (Property), 1908 (Home Services), 2693 (Car Services), 2669 (Tuition Services), 2662 (Business Services), 1920 (Jobs) |
| TW | 1668284 | 311 (Cars), 332 (Property), 1972 (Services), 1946 (Jobs) |
| ID | 1643084 | 274 (Cars), 295 (Property), 1866 (Services), 1879 (Jobs) |

> **Note**: The comment in `global.go` for SG mentions "Business Services" but it is **not** in the actual slice — likely intentional.

---

## `Category` behavior

- **IDs**: string IDs (e.g. country collection id); **`LegacyID`** is the legacy collection id used with **`GetCategoryByCountryIDAndLegacyID`**.
- **Localization**: `GetNameByTag` / `GetDisplayNameByTag` / `GetSEONameByTag`, or string-locale helpers `GetName`, `GetDisplayName`, `GetSEOName`. Supported CSV language tags are limited (**`global.go`** `csvLanguageMap`).
- **Subcategories**: populated after `buildCategoryTrees` in **`Init`**; `Subcategories` sorted by **`SortOrder`**.
- **Flags**: `Category.Flags` from remote/default JSON; platform gates via `PlatformBooleanFlag.GetFlag`.

---

## Tests (this repo)

Tests typically **`Init(category.CategoryOpts{IsStaging: true})`** or **`OfflineMode: true`** depending on network; see **`category/setup_test.go`**. CLI behavior is covered above in **`categoryclient` commands**.

---

## Change checklist

- **New fields on categories/metadata**: likely need CSV structs in `transformers.go` / CSV pipeline and **`buildIDMaps`** / **`transformCategory`**.
- **New remote files**: extend `remotePaths`, `localBytes`, `downloadCSV`, and **`offlinemode`** embeddings if tests must stay offline.
- **Do not assume `Init` was called** in library helpers that read globals; callers own lifecycle.

---

## Reference in repo

- **`.claude/settings.json`**: Claude Code defaults (`acceptEdits` + **`Bash(categoryclient *)`** and common **`go` / `make`** rules). Override privately with **`.claude/settings.local.json`** (gitignored).
- Root **`README.md`**: integration snippet and `categoryclient` usage.
- **`category/README.md`**: maintainer TODOs only.
- Project Cursor skill: `.cursor/skills/categorylib/SKILL.md` in the categorylib checkout.
