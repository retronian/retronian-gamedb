# Retronian GameDB - Project Context

A retro game database focusing on **native scripts** (Japanese, Korean, Chinese, etc.) with first-class support for ISO 15924 script tags. It provides a structured, multi-language API and static HTML views.

## Project Overview

- **Purpose:** To solve the "romanization-only" problem in major game databases by providing high-quality native script metadata for retro games.
- **Architecture:** Static site generator approach. Data is stored in individual JSON files, processed by Ruby scripts, and deployed as a static API + HTML website via GitHub Pages.
- **Core Value:** The `script` field in titles, distinguishing between Hiragana, Katakana, and Kanji-mixed Japanese.

## Technical Stack

- **Language:** Ruby (for data processing and build scripts).
- **Data Format:** JSON files following `schema/game.schema.json`.
- **Infrastructure:** GitHub Pages, GitHub Actions.
- **Data Sources:** Wikidata, IGDB, No-Intro, libretro-thumbnails, and local curated databases (romu, gamelist-ja, skyscraper-ja).

## Building and Running

### Prerequisites
- Ruby 3.3+
- `gh` CLI (signed in, for libretro-thumbnails art)
- (Optional) Twitch/IGDB API credentials for augmentation.

### Key Commands
- **Build the API and Site:**
  ```bash
  ruby scripts/build_api.rb
  ```
  Generates the `dist/` directory with JSON API and HTML pages.

- **Full Data Pipeline (Summary):**
  1. `ruby scripts/fetch_wikidata.rb [platform]` - Seed data.
  2. `ruby scripts/fetch_igdb.rb --search` - Augment with IGDB.
  3. `ruby scripts/merge_romu.rb` / `scripts/merge_skyscraper_ja.rb` - Merge local data.
  4. `ruby scripts/dedupe.rb` - Clean up duplicates.
  5. `ruby scripts/merge_no_intro.rb` - Import ROM metadata.
  6. `ruby scripts/fetch_covers.rb` - Match cover art.
  7. `ruby scripts/build_api.rb` - Build distribution.

## Development Conventions

- **Data Integrity:** All changes to game data MUST adhere to `schema/game.schema.json`.
- **Surgical Changes:** Modify individual game JSON files in `data/games/{platform}/{id}.json` directly for manual corrections.
- **Commit Style:** Small, descriptive commits. No squashing.
- **Code Style:** Prefer Ruby for maintainable logic. Use `$stdout.sync = true` in scripts to ensure progress is visible in logs.
- **Naming:** Slugs are lowercase ASCII with hyphens (e.g., `hoshi-no-kirby`).

## Directory Structure

- `data/games/`: Canonical data store. Subdivided by platform.
- `schema/`: Contains `game.schema.json`, the authoritative schema.
- `scripts/`: Ruby scripts for fetching, merging, deduplicating, and building.
- `dist/`: Build output (gitignored).
- `.github/workflows/`: CI/CD pipeline for building and deploying to GitHub Pages.

## Important Notes

- **Language-Script Distinction:** `ja` language with `Jpan`, `Hira`, or `Kana` script tags is the primary focus.
- **Region vs. Language:** Keep region (where it was released) and language (what's on the box/in-game) axes separate.
- **Local Data Dependencies:** Many merge scripts expect sibling directories (e.g., `../romu`, `../no-intro-dat`) to exist for local data ingestion.
- **Site URL:** https://gamedb.retronian.com/ (Custom domain).
