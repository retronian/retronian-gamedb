# retronian-gamedb — AI handoff document

This document brings another AI assistant (or a new collaborator) up to
speed on the state of `retronian/retronian-gamedb`. It covers the goal,
the architecture, the scripts, the current data, the outstanding work,
and every environment-specific dependency you need to know about.

Last updated after commit `6e0b19aa`
(2026-04-11, switch GitHub Pages to `gamedb.retronian.com`).

---

## 1. What this project is

A retro game database built around the idea that **every title has an
ISO 15924 `script` tag** in addition to an ISO 639-1 `lang`. That
distinction matters in practice because major databases (ScreenScraper,
TheGamesDB, IGDB, MobyGames, Wikidata) cannot tell "katakana only" apart
from "kanji mixed in" even when you ask for Japanese.

- Static JSON API + HTML views, served from GitHub Pages.
- One game = one JSON file at `data/games/{platform}/{id}.json`.
- Build output goes to `dist/` (gitignored) and is deployed by a
  GitHub Actions workflow on every push to `main`.

### Live

- Repo: https://github.com/retronian/retronian-gamedb
- Current Pages URL: https://gamedb.retronian.com/
- Custom domain being set up: **`gamedb.retronian.com`**
  - `dist/CNAME` already contains this value and GitHub Pages already
    knows about it.
  - **The DNS record has not been added yet.** See §9.

---

## 2. Completed roadmap

| Phase | Description | Status |
|---|---|---|
| Phase 0 | Schema design, repo layout | done |
| Phase 1 | Wikidata SPARQL seed scraper (9 languages) | done |
| Phase 2 | IGDB augmentation (`--search` + batch fetch) | done |
| Phase 3 | Static API, GitHub Pages, HTML views, contrib docs | done |
| Phase 4 | Issue templates | done |
| Extra  | 5 more platforms (ps1/vb/ngp/gg/ms) to cover OneOS | done |
| Extra  | External merges from romu, skyscraper-ja, gamelist-ja | done |
| Extra  | Slug normalization pass, dedupe, no-intro DAT import | done |
| Extra  | libretro-thumbnails cover art + HTML media grid | done |

Phase 5 (romu integration) was explicitly dropped by the owner.

---

## 3. Current data

From `api/v1/stats.json` at the tip of `main`:

```
total games: 10457
platforms:
  fc 1172  sfc 1391  gb 500   gbc 433  gba 990
  md 1001  pce 323   n64 409  nds 1747 ps1 2009
  vb 24    ngp 37    gg 168   ms 253
languages: en 12207 ja 8381 fr 6907 it 4625 es 4212 de 3299 ko 2131 zh 1757
scripts:   Latn 31562 Kana 4465 Jpan 3526 Hang 2130 Hant 1045 Hans 712 Hira 79
```

Additional layers on top of the base `titles[]`:
- **14,567** `roms[]` entries imported from No-Intro DATs
  (name / region / serial / size / crc32 / md5 / sha1 / sha256)
- **33,809** `media[]` URLs from libretro-thumbnails across
  **5,947** games (boxart / titlescreen / screenshot).

---

## 4. Repository layout

```
retronian-gamedb/
├── AGENTS.md              project notes (Japanese)
├── HANDOFF.md             this file
├── README.md              user-facing English README
├── schema/
│   └── game.schema.json   JSON Schema Draft 2020-12
├── data/
│   └── games/{platform}/{id}.json   canonical store, one game per file
├── scripts/
│   ├── Gemfile            minimal (json-schema)
│   ├── lib/
│   │   ├── script_detector.rb   ja text -> ISO 15924 (Jpan/Hira/Kana/...)
│   │   └── slug.rb              slugify + Roman numeral aliases
│   ├── fetch_wikidata.rb      Phase 1 SPARQL scraper (9 platforms + 5 extras)
│   ├── fetch_igdb.rb          Phase 2, --search resolves missing IGDB ids
│   ├── fetch_covers.rb        libretro-thumbnails cover art -> media[]
│   ├── merge_romu.rb          romu gamedb -> titles/descriptions/date
│   ├── merge_skyscraper_ja.rb skyscraper-ja SHA1 matches -> ja titles
│   ├── merge_gamelist_ja.rb   gamelist-ja title_db -> ja titles
│   ├── merge_no_intro.rb      No-Intro DAT -> roms[]
│   ├── dedupe.rb              union same-external-id entries
│   └── build_api.rb           produces everything under dist/
├── .github/
│   ├── workflows/build.yml          Ruby 3.3, ruby scripts/build_api.rb, deploy
│   └── ISSUE_TEMPLATE/              data/bug forms + config
└── .gitignore                       dist/, .igdb_token.json, bundle/vendor
```

`dist/` is never committed. The Actions workflow rebuilds it from
scratch on each push and publishes through
`actions/upload-pages-artifact@v3` + `actions/deploy-pages@v4`.

---

## 5. Schema (summary)

`schema/game.schema.json` is authoritative. The top-level shape:

```jsonc
{
  "id": "hoshi-no-kirby",
  "platform": "gb",
  "category": "main_game",
  "first_release_date": "1992-04-27",
  "titles": [
    {
      "text": "星のカービィ",
      "lang": "ja",
      "script": "Jpan",          // ISO 15924
      "region": "jp",
      "form": "boxart",          // official/boxart/ingame_logo/manual/...
      "source": "wikidata",      // wikidata/igdb/romu/gamelist_ja/...
      "verified": true
    }
  ],
  "descriptions": [{"text": "...", "lang": "ja", "source": "romu"}],
  "developers": ["hal-laboratory"],
  "publishers": ["nintendo"],
  "genres": ["platformer"],
  "external_ids": { "wikidata": "Q...", "igdb": 1063, "mobygames": 6610 },

  "roms": [
    {
      "name": "Kirby's Dream Land (USA, Europe)",
      "region": "us",
      "serial": "DMG-KB-USA",
      "size": 131072,
      "crc32": "...", "md5": "...", "sha1": "...", "sha256": "...",
      "source": "no_intro"
    }
  ],
  "media": [
    {
      "kind": "boxart",          // boxart/boxart_back/titlescreen/screenshot/...
      "url": "https://raw.githubusercontent.com/libretro-thumbnails/.../.png",
      "region": "us",
      "source": "libretro_thumbnails"
    }
  ]
}
```

Valid `platform` values (enum): `fc sfc gb gbc gba md pce n64 nds ngp ws wsc ps1 vb gg ms`.
(`ws`, `wsc` are in the enum but no data has been collected for them yet.)

Valid `script` values: `Jpan Hira Kana Hans Hant Hang Kore Latn Cyrl Arab Hebr Thai Zyyy`.

---

## 6. Scripts — what each one does

### Phase 1: seeding
- `scripts/fetch_wikidata.rb [platform] [--dry-run] [--limit N]`
  SPARQL to Wikidata. Takes the platform QIDs in `PLATFORMS` (now
  supports multiple QIDs per platform — ngp uses both
  `Q939881` and `Q1977455`). Uses a subquery + `GROUP BY ?item` with
  `SAMPLE()` to avoid cartesian product explosions from the optional
  language labels. Retries with exponential backoff on transient HTTP
  errors. Writes `data/games/{platform}/{slug}.json`.

### Phase 2: IGDB augmentation
- `scripts/fetch_igdb.rb [--search] [--platform X] [--dry-run]`
  Twitch OAuth client credentials flow. Caches the token in
  `.igdb_token.json` (gitignored). With `--search` it first resolves an
  IGDB id for every entry that lacks one by searching the English title
  on the matching IGDB platform. Then it does batch POSTs to
  `/v4/games` (up to 500 ids per request, throttled to ~3 req/s) and
  expands `game_localizations.{name,region}` and `alternative_names.{name,comment}`.
  `safe_to_merge?` uses token-set overlap divided by **max** length
  to refuse a merge when the IGDB `game.name` does not match the local
  English title — that's what caught the 39 bogus Wikidata IGDB ids.

### External merges
- `scripts/merge_romu.rb`
  Pulls `title_ja`, `desc_ja`, `release_date` out of
  `../romu/internal/gamedb/data/{platform}.json`.
  The biggest win here was long-form `desc_ja` that Wikidata/IGDB do
  not have.
- `scripts/merge_skyscraper_ja.rb`
  Walks `*_matches.csv` in `../skyscraper-ja/csv/`,
  picks only rows with `status=matched` (SHA1-verified), and merges
  `ja_title` as `verified=true`.
- `scripts/merge_gamelist_ja.rb`
  Uses `../gamelist-ja/db/title_db/{platform}.json`.
  Records `pigsaint/manual/offlinelist/mame/gamelist` sources as
  verified but never marks `deepl` as verified.
- `scripts/merge_no_intro.rb`
  Parses DATs from `../no-intro-dat/`
  (REXML). Each `<rom>` becomes a `roms[]` entry with hashes + serial
  + size + derived region.

### Data hygiene
- `scripts/dedupe.rb`
  Two entries count as duplicates if they share any of
  `wikidata` / `igdb` / `mobygames` external ids. Union-merges their
  titles / descriptions / developers / publishers / genres /
  `external_ids`, keeps the earlier `first_release_date`, prefers the
  file whose `id` matches the canonical English-title slug. Wipes
  245 files down to 10,457 from 10,702.

### Covers
- `scripts/fetch_covers.rb [--platform X] [--dry-run]`
  For each retronian-gamedb platform it calls
  `gh api repos/libretro-thumbnails/<repo>/git/trees/master?recursive=1`
  (falls back to `main`) and indexes every PNG under
  `Named_Boxarts/`, `Named_Snaps/`, `Named_Titles/`. It then walks the
  games and, for every `rom.name`, looks up an identical PNG filename.
  If no rom matched (e.g. platforms without a DAT like vb/gg/ms/ngp),
  it falls back to trying the English title plus common region
  suffixes (`" (Japan)"`, `" (USA)"`, `" (Europe)"`, etc).

### Build
- `scripts/build_api.rb`
  Consumes `data/games/**/*.json` and produces everything under
  `dist/`: the JSON API, the HTML landing page, per-platform listing
  pages, one HTML page per game (with a media grid + a collapsible
  ROM hash table), the schema and contributing doc pages, and
  `dist/CNAME` for the custom domain.

### Shared libs
- `scripts/lib/script_detector.rb`
  Uses Ruby Unicode property regexes (`\p{Hiragana}`, `\p{Katakana}`,
  `\p{Han}`, `\p{Hangul}`, `\p{Latin}`, `\p{Cyrillic}`) to pick one of
  `Jpan/Hira/Kana/Hang/Latn/Cyrl/Zyyy`. Japanese text with any kanji
  returns `Jpan`; text with only one of hira/kana returns that alone.
- `scripts/lib/slug.rb`
  `Slug.slugify(text)` — canonical ASCII-hyphen slug.
  `Slug.aliases_for(text)` — canonical + numerals substituted (`ii->2`,
  `iii->3`, ...) + `the` stripped. Every merge script uses
  `Slug.aliases_for` when building its index and when looking up the
  incoming key so that "Double Dragon II: The Revenge" matches
  "double-dragon-2-the-revenge".

---

## 7. External data sources

All are on the local machine.

| Source | Path | Used by |
|---|---|---|
| No-Intro DATs | `../no-intro-dat/*.dat` | `merge_no_intro.rb` |
| romu gamedb | `../romu/internal/gamedb/data/*.json` | `merge_romu.rb` |
| skyscraper-ja | `../skyscraper-ja/csv/*_matches.csv` | `merge_skyscraper_ja.rb` |
| gamelist-ja | `../gamelist-ja/db/title_db/*.json` | `merge_gamelist_ja.rb` |
| libretro-thumbnails | `github.com/libretro-thumbnails/<repo>` (remote, via `gh api`) | `fetch_covers.rb` |
| Wikidata | `query.wikidata.org/sparql` (remote) | `fetch_wikidata.rb` |
| IGDB | `api.igdb.com/v4` (remote, Twitch OAuth) | `fetch_igdb.rb` |

Still not wired up:
- `retronian/romlists/*.csv` — has descriptions (especially `nes.csv`).
  Potential future merge; not critical.
- `NES_Header_Repair` — purely a ROM-repair tool, probably
  not useful here.

---

## 8. How to re-run the pipeline from scratch

```bash
# 1. Seed from Wikidata (all platforms, one at a time)
for p in fc sfc gb gbc gba md pce n64 nds ps1 vb ngp gg ms; do
  ruby scripts/fetch_wikidata.rb "$p"
done

# 2. IGDB resolve + augment (requires Twitch credentials)
export IGDB_CLIENT_ID=...
export IGDB_CLIENT_SECRET=...
ruby scripts/fetch_igdb.rb --search

# 3. External merges
ruby scripts/merge_romu.rb
ruby scripts/merge_skyscraper_ja.rb
ruby scripts/merge_gamelist_ja.rb

# 4. Deduplicate
ruby scripts/dedupe.rb

# 5. Import No-Intro DATs
ruby scripts/merge_no_intro.rb

# 6. Cover art
ruby scripts/fetch_covers.rb

# 7. Build
ruby scripts/build_api.rb
```

Pure rebuild of the site (no data changes) is just step 7.

---

## 9. Outstanding tasks

### 🔴 Blocking the custom domain cutover
- **Add a DNS CNAME record `gamedb.retronian.com -> retronian.github.io`**
  in Cloudflare (that's where `retronian.com` is managed). GitHub Pages
  already has `gamedb.retronian.com` configured as the custom domain and
  the repo has `dist/CNAME` baked in. Until the CNAME record exists the
  only working URL is https://gamedb.retronian.com/.
  Attempted automation was blocked because Cloudflare credentials are
  in 1Password (`op` not signed in) and no API token was available in
  the shell environment. The owner offered to provide a
  `CF_API_TOKEN` — that's the next concrete step.

### 🟡 Nice-to-have data work
- **`retronian/romlists/nes.csv`** has long Japanese descriptions that
  could flesh out `descriptions[]` further. Worth a small merge script.
- **Unmatched slugs**: the external merges still leave ~3k entries
  unmatched because the source spellings drift further than
  `Slug.aliases_for` handles (punctuation, compilation sub-titles,
  localized punctuation). A smarter fuzzy matcher (RapidFuzz / Jaro)
  would recover a few hundred more.
- **`fetch_igdb.rb` rerun** after the slug normalization changes might
  resolve a few more IGDB ids. Not urgent.

### 🟢 Future ideas (nobody has asked yet)
- Community-contribution automation: GitHub Actions workflow that
  converts a parsed issue form into a JSON diff PR.
- License decision (currently "TBD" in README).
- `ws` / `wsc` platforms (WonderSwan) — they are already in the schema
  enum but have no data yet.
- No-JS search. The owner does not want a JS-heavy search page; a
  per-platform A–Z index under `/platforms/{p}/a/`, `/b/`, ... would
  give decent discovery with plain HTML.
- An actual LICENSE file.

---

## 10. Secrets / credentials

- **Twitch (IGDB)** client id/secret are **not stored in the repo**.
  They were set in-shell with `IGDB_CLIENT_ID=... IGDB_CLIENT_SECRET=...`
  and the access token is cached in `.igdb_token.json` (gitignored,
  valid ~64 days).
- **Cloudflare API token** is not on disk. The owner has it in
  1Password. You will need to ask for one scoped to `Zone.DNS:Edit`
  on `retronian.com` to add the CNAME record.
- **GitHub auth**: the local `gh` is already signed in as
  `retronian` (owner of the repo). `gh api` calls just work.

Never commit any of these.

---

## 11. Owner preferences (from conversation)

- The owner prefers **Ruby** for code you will have to read, and Go
  when you need speed. Python is fine for throwaway scripts but
  avoided for anything maintained.
- The site is **English-first**. Project agent instructions live in AGENTS.md. The conversation with the owner is in
  Japanese — respond in Japanese unless the deliverable is code,
  commit messages, or a user-facing page.
- Commits are small and descriptive. No squashing, no `--no-verify`,
  no force pushes to `main`. Always create a new commit rather than
  amending a pushed one.
- The owner explicitly does **not** want:
  - romu integration (we were going to `go:embed` this DB into romu
    but that scope has been dropped)
  - a heavy JavaScript frontend
- Background processes: long-running shell commands should go in the
  background (`run_in_background: true`) and be monitored via
  notifications. `$stdout.sync = true` at the top of every Ruby script
  is necessary to make progress visible through `tee` / log files.
- Never execute destructive git operations (`reset --hard`,
  force push, `-D`) without explicit approval.

---

## 12. Known quirks and gotchas

- **Wikidata `P5794` (IGDB id) is unreliable.** ~90% of the
  inherited IDs were wrong; `fetch_igdb.rb` deletes them on
  mismatch via `safe_to_merge?`.
- **IGDB `regions` only returns three rows** (`ja-JP`, `ko-KR`, `EU`)
  at the time of writing. The older `release_dates.region` enum is a
  separate, deprecated table. Do not confuse the two.
- **The IGDB `/games` search + `where platforms = (...)` query works**
  even though some forum threads claim otherwise. `limit 500` is the
  hard maximum.
- **libretro-thumbnails** uses `master` for most repos. `fetch_covers.rb`
  tries `master` first, then falls back to `main`.
- **FFVI had a hand-written bad `igdb: 385`** in the Phase 0 seed — that
  was the original Final Fantasy. It has been removed but is a good
  cautionary tale if you add any more hand-written samples.
- The sample files `hoshi-no-kirby.json`, `super-mario-bros.json`,
  `final-fantasy-vi.json` started life hand-written in Phase 0 and
  still exist alongside the Wikidata-seeded versions (`kirbys-dream-land.json`,
  etc). `dedupe.rb` did not merge them because their external ids did
  not overlap. Not a bug today; worth cleaning up eventually.
- **GitHub Pages CI has Node 20 deprecation warnings**. Harmless until
  June 2nd 2026; bumping the actions to v5 is the fix.

---

## 13. Useful endpoints for verification

Once the CNAME resolves:

- https://gamedb.retronian.com/
- https://gamedb.retronian.com/api/v1/stats.json
- https://gamedb.retronian.com/api/v1/platforms.json
- https://gamedb.retronian.com/api/v1/gb.json
- https://gamedb.retronian.com/api/v1/games/gb/kirbys-dream-land.json
- https://gamedb.retronian.com/games/gb/kirbys-dream-land.html
- https://gamedb.retronian.com/docs/schema.html
- https://gamedb.retronian.com/docs/contributing.html

Until then the same paths work at `https://gamedb.retronian.com/`.
