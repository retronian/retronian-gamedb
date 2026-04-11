# Native Game DB

A retro game database with first-class support for **native scripts** — the original written form of game titles in Japanese (hiragana, katakana, kanji), Korean (hangul), Chinese (hanzi), and other non-Latin writing systems.

## Why this exists

Major retro game databases (ScreenScraper.fr, TheGamesDB, IGDB, MobyGames, etc.) all suffer from a structural problem: even when you set the region to Japan, they return romanized titles. Native script data is either missing or scattered across unstructured fields you cannot reliably query.

Native Game DB provides:

- **Structured multi-language, multi-script title metadata**
- **Distinction between hiragana / katakana / kanji-mixed Japanese** (via ISO 15924)
- **Fully serverless distribution** (static JSON over GitHub Pages)
- **GitHub-based community contributions** (Issue → automated PR)

## What makes it different

The key differentiator — absent from every other game DB — is the **`script` column** on each title, encoded with [ISO 15924](https://en.wikipedia.org/wiki/ISO_15924).

| Title | `lang` | `script` | Meaning |
|---|---|---|---|
| 星のカービィ | `ja` | `Jpan` | Japanese with kanji mixed in |
| ほしのカービィ | `ja` | `Hira` | Hiragana only |
| スーパーマリオブラザーズ | `ja` | `Kana` | Katakana only |
| Hoshi no Kirby | `ja` | `Latn` | Romaji transliteration |
| Kirby's Dream Land | `en` | `Latn` | English |

The language tag `ja` alone cannot express the difference between "katakana only" and "kanji mixed in". Many early Famicom titles use katakana exclusively, and this distinction matters in practice when working with retro game metadata.

## Data layout

One game = one JSON file (`data/games/{platform}/{id}.json`).

```json
{
  "id": "hoshi-no-kirby",
  "platform": "gb",
  "category": "main_game",
  "first_release_date": "1992-04-27",
  "titles": [
    { "text": "星のカービィ", "lang": "ja", "script": "Jpan", "region": "jp", "form": "boxart", "source": "wikidata", "verified": true },
    { "text": "Kirby's Dream Land", "lang": "en", "script": "Latn", "region": "us", "form": "official", "source": "wikidata", "verified": true }
  ],
  "developers": ["hal-laboratory"],
  "publishers": ["nintendo"],
  "genres": ["platformer"],
  "external_ids": {
    "wikidata": "Q1064715",
    "igdb": 1083
  }
}
```

See [`schema/game.schema.json`](schema/game.schema.json) for the full schema.

### The 7 axes of `titles[]`

- `text` — the title string
- `lang` — ISO 639-1 language code (`ja` / `en` / `ko` / `zh` / ...)
- `script` — **ISO 15924 script code** (`Jpan` / `Hira` / `Kana` / `Hans` / `Hant` / `Latn` / ...)
- `region` — ISO 3166-1 country code, lowercase (`jp` / `us` / `eu` / `kr` / ...)
- `form` — `official` / `boxart` / `ingame_logo` / `manual` / `romaji_transliteration` / `alternate`
- `source` — `wikidata` / `igdb` / `mobygames` / `screenscraper` / `no_intro` / `community` / `manual`
- `verified` — whether the entry has been confirmed against a primary source (title screen, original packaging)

## Static API

The database is published as static JSON over GitHub Pages: **https://gamedb.retronian.com/**

| Endpoint | Description |
|---|---|
| `/api/v1/platforms.json` | List of supported platforms with counts |
| `/api/v1/stats.json` | Aggregate statistics |
| `/api/v1/{platform}.json` | All games for a platform (e.g. `gb.json`) |
| `/api/v1/games/{platform}/{id}.json` | A single game entry |
| `/search-index/all.json` | Minimal index for client-side search |

## Supported platforms

Famicom (`fc`), Super Famicom (`sfc`), Game Boy (`gb`), Game Boy Color (`gbc`), Game Boy Advance (`gba`), Mega Drive (`md`), PC Engine (`pce`), Nintendo 64 (`n64`), Nintendo DS (`nds`)

## Design principles

The schema borrows the strongest ideas from existing game DBs and avoids their failure modes:

- **Wikidata-style**: every value carries a language tag
- **ScreenScraper-style**: region axis and language axis are kept separate
- **IGDB-style**: release dates are independent rows per `(region × platform)`
- **Anti-pattern from MobyGames**: no free-text disambiguation labels — use structured enums
- **Anti-pattern from TheGamesDB**: no bare arrays of strings without language metadata
- **Native Game DB original**: the `script` column (ISO 15924)

## Roadmap

- [x] **Phase 0** — Schema design and directory layout
- [x] **Phase 1** — Wikidata SPARQL scraper for the initial seed (multilingual)
- [x] **Phase 2** — Augment titles with IGDB `game_localizations` and `alternative_names`
- [x] **Phase 3** — Static API and HTML views via GitHub Pages
- [x] **Phase 4** — Community contribution flow (GitHub issue templates)

## Related projects

- [komagata/gamelist-ja](https://github.com/komagata/gamelist-ja) — EmulationStation `gamelist.xml` generator with Japanese titles (predecessor)
- [komagata/skyscraper-ja](https://github.com/komagata/skyscraper-ja) — Japanese title import for Skyscraper cache (predecessor)
- [retronian/OneOS](https://github.com/retronian/OneOS) — MinUI fork with Japanese support (data consumer)

## Contributing

Issue templates and the automated PR pipeline are coming in Phase 4. For now, please open a regular issue or pull request.

## License

To be decided (likely CC0 or MIT).
