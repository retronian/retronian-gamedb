# Manually-collected media

Drop boxart / title screen / screenshot / cartridge images here. The
`scripts/import_local_media.rb` build step walks this directory and
links each file to the matching game entry's `media[]` array.

## Folder convention

```
media/{kind}/{platform}/{filename}
```

- `kind` — one of `boxart`, `boxart_back`, `titlescreen`, `screenshot`,
  `cartridge`, `disc`, `logo`
- `platform` — one of `fc`, `sfc`, `gb`, `gbc`, `gba`, `md`, `pce`,
  `n64`, `nds`, `ps1`
- `filename` — `{game_id}[-{region}][-{tag}].{ext}`
  - `ext` — `png`, `jpg`, `jpeg`, `webp`, or `gif`
  - `region` — `jp`, `us`, `eu`, `kr`, `cn`, `tw`, `hk`, `au`, `br`.
    Optional; defaults to `jp` if omitted (this DB is native-script
    focused, so JP is the most common region).
  - `tag` — anything else, kept in the filename but ignored for
    metadata; use it to disambiguate revisions or variants
    (e.g. `-rev1`, `-alt`).

## Examples

```
media/boxart/gb/tv-champion.jpg              # JP boxart (default region)
media/boxart/gb/tv-champion-us.jpg           # US boxart
media/boxart/sfc/final-fantasy-vi-rev1.jpg   # JP boxart, Rev 1 scan
media/titlescreen/fc/hoshi-no-kirby.png
media/cartridge/n64/super-mario-64.jpg
```

## Workflow

1. Put the file in the right `media/{kind}/{platform}/` subdirectory.
2. Name it using the game's `id` — e.g. `data/games/gb/tv-champion.json`
   -> filename starts with `tv-champion`.
3. Run `ruby scripts/import_local_media.rb` to link it. The script
   appends a `media[]` entry whose URL is:
   `https://raw.githubusercontent.com/retronian/native-game-db/main/media/{kind}/{platform}/{filename}`
4. Commit both the image file and the updated `data/games/.../*.json`.

## Licensing

Anything you commit here is redistributed under the project's
[CC BY-SA 4.0](../LICENSE-DATA) data license. Only upload images you
have the right to redistribute: photos you took yourself, scans of
your own boxes, or images from CC-licensed / public-domain sources.
Do not upload images lifted from commercial databases
(MobyGames, IGDB, ScreenScraper) or publisher press kits.
