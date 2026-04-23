#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate data/games/{platform}/*.json into the GitHub Pages
# distribution directory dist/.
#
# Output:
#   dist/index.html                              landing page
#   dist/platforms/{platform}/index.html         per-platform game list
#   dist/games/{platform}/{id}.html              individual game page
#   dist/docs/contributing.html                  contributor guide
#   dist/docs/schema.html                        schema spec for scraper authors
#   dist/api/v1/platforms.json                   platform metadata
#   dist/api/v1/stats.json                       aggregate statistics
#   dist/api/v1/{platform}.json                  all games for a platform
#   dist/api/v1/games/{platform}/{id}.json       individual game JSON
#   dist/search-index/all.json                   client-side search index
#
# Usage:
#   ruby scripts/build_api.rb

require 'json'
require 'fileutils'
require 'time'
require 'cgi'

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
DIST = File.join(ROOT, 'dist')
API  = File.join(DIST, 'api', 'v1')
INDEX_DIR = File.join(DIST, 'search-index')
API_VERSION = 'v1'
CNAME = 'gamedb.retronian.com'

PLATFORMS = {
  'fc'  => 'Famicom / NES',
  'sfc' => 'Super Famicom / SNES',
  'gb'  => 'Game Boy',
  'gbc' => 'Game Boy Color',
  'gba' => 'Game Boy Advance',
  'md'  => 'Mega Drive / Genesis',
  'pce' => 'PC Engine / TurboGrafx-16',
  'n64' => 'Nintendo 64',
  'nds' => 'Nintendo DS',
  'ps1' => 'PlayStation'
}.freeze

# A game counts as "released in Japan" when we have a No-Intro ROM
# tagged region=jp that is *not* a prototype, beta, pirate dump,
# unlicensed release, homebrew or BIOS. Only retail releases count.
#
# Wikidata and IGDB labels would happily assign ja tags to games that
# never shipped in Japan (localized Wikipedia article titles etc), so
# we rely on No-Intro's region tagging as ground truth and strip the
# non-retail bucket explicitly.
NON_RETAIL_ROM_RE = /\((?:Proto|Possible Proto|Beta|Unl|Pirate|Sample|Demo|Hack|Aftermarket|Homebrew)(?:\s+\d+)?\)/i.freeze

# Native-script languages we track coverage for. Each maps to the
# No-Intro region codes where that language is the local market, plus
# the ISO 15924 scripts that count as "native" (i.e. not a romanized
# fallback).
NATIVE_LANGS = {
  'ja' => { name: '日本語', regions: %w[jp],       scripts: %w[Jpan Hira Kana] },
  'ko' => { name: '한국어',  regions: %w[kr],       scripts: %w[Hang] },
  'zh' => { name: '中文',    regions: %w[cn tw hk], scripts: %w[Hans Hant] }
}.freeze

def bios_entry?(game)
  game['id'].to_s.start_with?('bios-') || (game['category'] || '') == 'bios'
end

def released_in_region?(game, region)
  return false if bios_entry?(game)
  (game['roms'] || []).any? do |r|
    next false unless r['region'] == region
    next false if r['name'].to_s =~ NON_RETAIL_ROM_RE
    true
  end
end

def released_in_any?(game, regions)
  regions.any? { |r| released_in_region?(game, r) }
end

# Any title in the given language (including Latin transliterations).
def has_title_in_lang?(game, lang)
  game['titles'].any? { |t| t['lang'] == lang }
end

# A title whose script matches one of the native-script codes for lang
# (Jpan/Hira/Kana for ja, Hang for ko, Hans/Hant for zh, etc.). Latin
# entries don't count.
def has_native_script_title?(game, lang)
  scripts = NATIVE_LANGS.dig(lang, :scripts) || []
  game['titles'].any? { |t| t['lang'] == lang && scripts.include?(t['script']) }
end

# ---------------------------------------------------------------------------
# Loaders / writers

def load_games(platform_id)
  dir = File.join(SRC, platform_id)
  return [] unless Dir.exist?(dir)
  Dir.glob(File.join(dir, '*.json')).sort.map { |f| JSON.parse(File.read(f)) }
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(data))
end

def write_pretty_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(data) + "\n")
end

def write_html(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
end

def h(text)
  CGI.escapeHTML(text.to_s)
end

def primary_title(game, lang)
  game['titles'].find { |t| t['lang'] == lang }
end

def display_title(game)
  # Prefer English for cross-locale readability on the site, then any
  # tracked native-script language, then whatever title is first.
  return primary_title(game, 'en')['text'] if primary_title(game, 'en')
  NATIVE_LANGS.each_key do |lang|
    t = primary_title(game, lang)
    return t['text'] if t
  end
  game['titles'].first&.dig('text') || game['id']
end

def search_doc(game)
  doc = { 'id' => game['id'], 'platform' => game['platform'] }
  game['titles'].each do |t|
    key = "#{t['lang']}_#{t['script']}"
    doc[key] ||= t['text']
  end
  doc['date'] = game['first_release_date'] if game['first_release_date']
  doc
end

# ---------------------------------------------------------------------------
# HTML layout

def layout(title:, body:, root_rel: '')
  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{h(title)} &middot; Native Game DB</title>
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Press+Start+2P&family=VT323&family=Noto+Sans+JP:wght@400;700&display=swap">
      <link rel="stylesheet" href="#{root_rel}assets/style.css">
    </head>
    <body>
      <header class="site-header">
        <a class="brand" href="#{root_rel}">NATIVE GAME DB</a>
        <nav>
          <a href="#{root_rel}">BROWSE</a>
          <a href="#{root_rel}docs/schema.html">SCHEMA</a>
          <a href="#{root_rel}docs/contributing.html">CONTRIB</a>
          <a href="https://github.com/retronian/native-game-db">GITHUB</a>
        </nav>
      </header>
      <main>
        #{body}
      </main>
      <footer class="site-footer">
        <p>&gt;&gt; <a href="https://github.com/retronian/native-game-db">retronian/native-game-db</a> &nbsp; * &nbsp; CC&nbsp;BY-SA&nbsp;4.0 / MIT &nbsp; * &nbsp; PRESS START &lt;&lt;</p>
      </footer>
    </body>
    </html>
  HTML
end

CSS = <<~CSS
  /* ================================================================
   * Native Game DB — Cathode Ray Cartridge
   *
   * 80s/90s arcade + CRT terminal vibe. Black phosphor background,
   * green readout, magenta + amber accents, scanline overlay,
   * pixel font for chrome (Press Start 2P), VT323 for body.
   * ================================================================ */

  :root {
    --bg:        #07090a;
    --bg-panel:  #0e1411;
    --bg-panel2: #131a16;
    --fg:        #c8f0d4;
    --fg-dim:    #7da08a;
    --fg-muted:  #4d6356;
    --line:      #2a3a30;
    --line-hard: #4a6a55;
    --accent:    #ff3366;
    --accent2:   #ffcc00;
    --cyan:      #4ee0ff;

    --glow-fg:     0 0 6px rgba(120, 220, 150, 0.5);
    --glow-strong: 0 0 8px rgba(120, 220, 150, 0.8), 0 0 16px rgba(120, 220, 150, 0.4);
    --glow-pink:   0 0 6px rgba(255, 51, 102, 0.7), 0 0 14px rgba(255, 51, 102, 0.35);
    --glow-amber:  0 0 6px rgba(255, 204, 0, 0.7), 0 0 14px rgba(255, 204, 0, 0.3);

    --font-pixel: "Press Start 2P", "Courier New", monospace;
    --font-term:  "VT323", "Courier New", "Noto Sans JP", monospace;
    --font-body:  "VT323", "Courier New", "Noto Sans JP", monospace;
  }

  * { box-sizing: border-box; }

  html, body {
    margin: 0;
    padding: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: var(--font-body);
    font-size: 20px;
    line-height: 1.45;
    text-shadow: var(--glow-fg);
    -webkit-font-smoothing: antialiased;
  }

  /* CRT scanlines overlay */
  body::before {
    content: "";
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 1000;
    background: repeating-linear-gradient(
      0deg,
      rgba(0, 0, 0, 0.18) 0px,
      rgba(0, 0, 0, 0.18) 1px,
      transparent 1px,
      transparent 3px
    );
  }

  /* CRT vignette + subtle phosphor cast */
  body::after {
    content: "";
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 999;
    background:
      radial-gradient(ellipse at center, transparent 45%, rgba(0, 0, 0, 0.55) 100%),
      radial-gradient(ellipse at top, rgba(120, 220, 150, 0.04) 0%, transparent 60%);
  }

  a {
    color: var(--accent);
    text-decoration: none;
    text-shadow: var(--glow-pink);
    transition: text-shadow 0.12s;
  }
  a:hover {
    color: var(--accent2);
    text-shadow: var(--glow-amber);
  }
  a::before { content: "["; opacity: 0.45; margin-right: 0.1em; }
  a::after  { content: "]"; opacity: 0.45; margin-left: 0.1em; }
  a.bare::before, a.bare::after { content: none; }

  /* ----- header / footer ----- */

  .site-header {
    max-width: 960px;
    margin: 0 auto;
    padding: 1.6rem 1.6rem 1.2rem;
    display: flex;
    align-items: center;
    gap: 1.6rem;
    border-bottom: 2px solid var(--line-hard);
    flex-wrap: wrap;
  }
  .site-header .brand {
    font-family: var(--font-pixel);
    font-size: 0.78rem;
    color: var(--accent);
    text-shadow: var(--glow-pink);
    margin-right: auto;
    letter-spacing: 0.05em;
    line-height: 1;
  }
  .site-header .brand::before { content: none; }
  .site-header .brand::after  { content: none; }
  .site-header .brand:hover {
    color: var(--accent2);
    text-shadow: var(--glow-amber);
  }
  .site-header nav {
    display: flex;
    gap: 1rem;
    font-family: var(--font-pixel);
    font-size: 0.55rem;
    line-height: 1;
  }
  .site-header nav a {
    color: var(--fg-dim);
    text-shadow: 0 0 4px rgba(120, 220, 150, 0.3);
  }
  .site-header nav a::before { content: none; }
  .site-header nav a::after  { content: none; }
  .site-header nav a:hover {
    color: var(--cyan);
    text-shadow: 0 0 6px rgba(78, 224, 255, 0.7), 0 0 14px rgba(78, 224, 255, 0.35);
  }

  .site-footer {
    max-width: 960px;
    margin: 5rem auto 0;
    padding: 1.6rem 1.6rem 2.6rem;
    border-top: 2px solid var(--line-hard);
    text-align: center;
    font-family: var(--font-term);
    font-size: 1rem;
    color: var(--fg-muted);
    letter-spacing: 0.08em;
  }
  .site-footer a {
    color: var(--fg-dim);
    text-shadow: 0 0 4px rgba(120, 220, 150, 0.3);
  }
  .site-footer a::before { content: none; }
  .site-footer a::after  { content: none; }

  /* ----- main column ----- */

  main {
    max-width: 960px;
    margin: 0 auto;
    padding: 2.6rem 1.6rem 1rem;
  }

  /* ----- typography ----- */

  h1 {
    font-family: var(--font-pixel);
    font-size: 1.4rem;
    line-height: 1.4;
    margin: 0 0 1.6rem;
    color: var(--accent2);
    text-shadow: var(--glow-amber);
    letter-spacing: 0.02em;
  }
  h2 {
    font-family: var(--font-pixel);
    font-size: 0.7rem;
    margin: 3.5rem 0 1.2rem;
    padding-bottom: 0.6rem;
    color: var(--accent);
    text-shadow: var(--glow-pink);
    border-bottom: 2px solid var(--line-hard);
    letter-spacing: 0.04em;
    line-height: 1.4;
  }
  h2::before {
    content: ">> ";
    color: var(--cyan);
    text-shadow: 0 0 6px rgba(78, 224, 255, 0.7);
  }
  h3 {
    font-family: var(--font-pixel);
    font-size: 0.6rem;
    margin: 2rem 0 0.8rem;
    color: var(--cyan);
    text-shadow: 0 0 6px rgba(78, 224, 255, 0.6);
    line-height: 1.4;
  }

  p { margin: 0 0 1rem; }
  .lead {
    font-size: 1.15rem;
    color: var(--fg);
    max-width: 60ch;
    margin: 0 0 1.6rem;
    line-height: 1.5;
  }

  /* ----- code ----- */

  code, pre {
    font-family: var(--font-term);
    background: var(--bg-panel);
    color: var(--cyan);
    text-shadow: 0 0 4px rgba(78, 224, 255, 0.4);
  }
  code {
    padding: 0 0.35em;
    border: 1px solid var(--line);
    font-size: 0.95em;
  }
  pre {
    padding: 1rem 1.2rem;
    overflow-x: auto;
    border: 1px solid var(--line-hard);
    line-height: 1.45;
    margin: 1rem 0 1.5rem;
  }
  pre code { background: none; border: none; padding: 0; font-size: inherit; }

  /* ----- tables ----- */

  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0.6rem 0 1.6rem;
    font-size: 1rem;
    border: 1px solid var(--line-hard);
    background: var(--bg-panel);
  }
  th, td {
    text-align: left;
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  th {
    font-family: var(--font-pixel);
    font-size: 0.55rem;
    color: var(--accent2);
    background: var(--bg-panel2);
    text-shadow: var(--glow-amber);
    border-bottom: 2px solid var(--line-hard);
    line-height: 1.6;
    letter-spacing: 0.03em;
  }
  td { color: var(--fg); }
  .stats-table th { width: 18%; }
  .stats-table td { width: 82%; }

  /* ----- platform grid (cartridge cards) ----- */

  .platform-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 0.8rem;
    list-style: none;
    padding: 0;
    margin: 0.8rem 0 0;
  }
  .platform-grid li {
    border: 2px solid var(--line-hard);
    background: var(--bg-panel);
    padding: 1rem 1.1rem 0.9rem;
    transition: border-color 0.15s, box-shadow 0.15s, transform 0.15s;
    position: relative;
  }
  .platform-grid li::before {
    content: "";
    position: absolute;
    top: 0; left: 0;
    width: 30%;
    height: 4px;
    background: var(--accent);
    box-shadow: 0 0 8px rgba(255, 51, 102, 0.6);
  }
  .platform-grid li:hover {
    border-color: var(--accent);
    box-shadow: 0 0 12px rgba(255, 51, 102, 0.35), inset 0 0 12px rgba(255, 51, 102, 0.1);
    transform: translateY(-1px);
  }
  .platform-grid li:hover::before {
    width: 100%;
    transition: width 0.25s ease-out;
  }
  .platform-grid a {
    font-family: var(--font-pixel);
    font-size: 0.65rem;
    color: var(--fg);
    line-height: 1.45;
    text-shadow: var(--glow-fg);
  }
  .platform-grid a::before { content: none; }
  .platform-grid a::after  { content: none; }
  .platform-grid a:hover {
    color: var(--accent2);
    text-shadow: var(--glow-amber);
  }
  .platform-grid strong { font-weight: normal; }
  .platform-grid .count {
    display: block;
    margin-top: 0.6rem;
    font-family: var(--font-term);
    font-size: 0.95rem;
    color: var(--fg-dim);
    letter-spacing: 0.04em;
  }
  .platform-grid code {
    background: none;
    border: none;
    padding: 0;
    color: var(--cyan);
    font-size: inherit;
  }

  /* ----- progress bars (LCD readout) ----- */

  .progress {
    position: relative;
    background: var(--bg-panel2);
    border: 2px solid var(--line-hard);
    height: 30px;
    margin: 0.8rem 0 0.5rem;
    overflow: hidden;
    box-shadow: inset 0 0 8px rgba(0, 0, 0, 0.6);
  }
  .progress-bar {
    position: absolute;
    top: 0;
    left: 0;
    bottom: 0;
    background:
      repeating-linear-gradient(
        90deg,
        var(--accent) 0px,
        var(--accent) 6px,
        rgba(255, 51, 102, 0.6) 6px,
        rgba(255, 51, 102, 0.6) 7px
      );
    box-shadow: 0 0 12px rgba(255, 51, 102, 0.6), inset 0 0 12px rgba(255, 200, 200, 0.25);
  }
  .progress-label {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-term);
    font-size: 1rem;
    color: var(--fg);
    text-shadow:
      0 0 4px var(--bg),
      0 0 4px var(--bg),
      0 0 4px var(--bg),
      var(--glow-fg);
    pointer-events: none;
    letter-spacing: 0.05em;
  }
  .progress-sm { height: 20px; margin-top: 0.6rem; }
  .progress-sm .progress-label { font-size: 0.85rem; }

  .target-note {
    font-family: var(--font-term);
    font-size: 0.95rem;
    color: var(--fg-dim);
    margin: 0.5rem 0 1.2rem;
    letter-spacing: 0.04em;
  }
  .target-note::before { content: "// "; color: var(--accent2); }

  /* ----- game list ----- */

  .game-list {
    list-style: none;
    padding: 0;
    margin: 0.6rem 0 0;
    border-top: 1px solid var(--line);
  }
  .game-list-item {
    display: flex;
    gap: 1rem;
    padding: 0.7rem 0.4rem;
    border-bottom: 1px solid var(--line);
    align-items: flex-start;
    transition: background 0.1s;
  }
  .game-list-item:hover {
    background: rgba(255, 51, 102, 0.06);
  }
  .game-list-item .thumb {
    flex: 0 0 56px;
    background: var(--bg-panel);
    border: 1px solid var(--line-hard);
  }
  .game-list-item .thumb img {
    width: 100%;
    height: auto;
    display: block;
    image-rendering: pixelated;
  }
  .game-list-item .info { flex: 1; min-width: 0; }
  .game-list-item a {
    font-size: 1.15rem;
    color: var(--fg);
    text-shadow: var(--glow-fg);
  }
  .game-list-item a::before { content: none; }
  .game-list-item a::after  { content: none; }
  .game-list-item a:hover {
    color: var(--accent);
    text-shadow: var(--glow-pink);
  }
  .game-list-item .meta {
    font-family: var(--font-term);
    font-size: 0.95rem;
    color: var(--fg-dim);
    margin-top: 0.2rem;
    line-height: 1.5;
  }
  .badge {
    display: inline-block;
    background: transparent;
    color: var(--cyan);
    padding: 0 0.4rem;
    border: 1px solid var(--cyan);
    font-family: var(--font-pixel);
    font-size: 0.5rem;
    line-height: 1.6;
    letter-spacing: 0.05em;
    text-shadow: 0 0 4px rgba(78, 224, 255, 0.5);
  }

  .verified-yes { color: var(--accent); text-shadow: var(--glow-pink); }
  .verified-no  { color: var(--fg-muted); }

  /* ----- media grid ----- */

  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 0.7rem;
    margin: 1rem 0 1.5rem;
  }
  .media-grid figure {
    margin: 0;
    border: 2px solid var(--line-hard);
    background: var(--bg-panel);
    padding: 0.4rem;
    transition: border-color 0.15s, box-shadow 0.15s;
  }
  .media-grid figure:hover {
    border-color: var(--accent);
    box-shadow: 0 0 12px rgba(255, 51, 102, 0.4);
  }
  .media-grid img {
    width: 100%;
    height: auto;
    display: block;
    image-rendering: pixelated;
  }
  .media-grid figcaption {
    font-family: var(--font-pixel);
    font-size: 0.5rem;
    color: var(--cyan);
    text-shadow: 0 0 4px rgba(78, 224, 255, 0.4);
    margin-top: 0.4rem;
    text-align: center;
    line-height: 1.4;
    letter-spacing: 0.04em;
  }

  /* ----- description tabs (CSS-only) ----- */

  .desc-tabs {
    border: 2px solid var(--line-hard);
    margin: 1rem 0 1.5rem;
    background: var(--bg-panel);
  }
  .desc-tabs input[type="radio"] { display: none; }
  .desc-tabs .tab-labels {
    display: flex;
    flex-wrap: wrap;
    border-bottom: 2px solid var(--line-hard);
    background: var(--bg-panel2);
  }
  .desc-tabs .tab-labels label {
    padding: 0.7rem 1rem;
    font-family: var(--font-pixel);
    font-size: 0.55rem;
    cursor: pointer;
    color: var(--fg-muted);
    border-right: 1px solid var(--line);
    user-select: none;
    transition: color 0.1s, text-shadow 0.1s;
    line-height: 1.4;
  }
  .desc-tabs .tab-labels label:hover {
    color: var(--cyan);
    text-shadow: 0 0 6px rgba(78, 224, 255, 0.6);
  }
  .desc-tabs .tab-labels label code {
    background: none;
    border: none;
    padding: 0;
    color: inherit;
    margin-left: 0.3rem;
    font-family: inherit;
    font-size: inherit;
    text-shadow: inherit;
  }
  .desc-tabs .tab-panels {
    padding: 1.3rem 1.5rem;
    font-family: var(--font-body);
    font-size: 1.1rem;
  }
  .desc-tabs .tab-panel { display: none; }
  .desc-tabs .tab-panel p {
    margin: 0 0 1.1rem;
    line-height: 1.55;
  }
  .desc-tabs .tab-panel p:last-child { margin-bottom: 0; }
  .desc-tabs .tab-panel .src {
    display: block;
    font-family: var(--font-pixel);
    font-size: 0.45rem;
    color: var(--accent2);
    text-shadow: var(--glow-amber);
    margin-bottom: 0.4rem;
    letter-spacing: 0.04em;
  }

  /* ----- responsive ----- */

  @media (max-width: 640px) {
    body { font-size: 18px; }
    main { padding: 1.6rem 1.1rem 0.5rem; }
    .site-header { padding: 1.1rem 1.1rem 0.9rem; }
    h1 { font-size: 1.05rem; }
    h2 { font-size: 0.62rem; }
    .platform-grid { grid-template-columns: 1fr; }
    .platform-grid a { font-size: 0.58rem; }
  }
CSS

# ---------------------------------------------------------------------------
# HTML pages

def render_landing(stats, platforms_meta)
  rows = platforms_meta.map { |p|
    bars = render_lang_progress_stack(p['by_lang'], size: :sm)
    <<~LI
      <li>
        <a href="platforms/#{p['id']}/"><strong>#{h(p['name'])}</strong></a>
        <div class="count">#{p['count']} games &middot; <code>#{p['id']}</code></div>
        #{bars}
      </li>
    LI
  }.join

  scripts_rows = stats['scripts'].map { |k, v|
    "<tr><th><code>#{h(k)}</code></th><td>#{v}</td></tr>"
  }.join

  langs_rows = stats['languages'].map { |k, v|
    "<tr><th><code>#{h(k)}</code></th><td>#{v}</td></tr>"
  }.join

  # Aggregate coverage per native-language across all platforms.
  overall_by_lang = NATIVE_LANGS.keys.each_with_object({}) do |lang, acc|
    rows_for_lang = platforms_meta.map { |p| p.dig('by_lang', lang) }.compact
    total   = rows_for_lang.sum { |r| r['total'] || 0 }
    named   = rows_for_lang.sum { |r| r['named'] || 0 }
    native  = rows_for_lang.sum { |r| r['native'] || 0 }
    pct     = total.positive? ? (named * 100.0 / total).round(1) : nil
    acc[lang] = { 'total' => total, 'named' => named, 'native' => native, 'percent' => pct }
  end

  overall_progress = render_lang_progress_stack(overall_by_lang, size: :lg)

  # Overall descriptions coverage by language.
  desc_total_overall = platforms_meta.sum { |p| p['desc_total'] || 0 }
  desc_by_lang_overall = Hash.new(0)
  platforms_meta.each do |p|
    (p['desc_by_lang'] || {}).each { |lang, n| desc_by_lang_overall[lang] += n }
  end

  desc_table = if desc_total_overall.positive?
                 desc_rows = desc_by_lang_overall.sort_by { |_, v| -v }.map do |lang, covered|
                   p = (covered * 100.0 / desc_total_overall).round(1)
                   width = p.clamp(0, 100)
                   <<~TR
                     <tr>
                       <th><code>#{h(lang)}</code></th>
                       <td style="width: 70%">
                         <div class="progress progress-sm">
                           <div class="progress-bar" style="width: #{width}%"></div>
                           <div class="progress-label">#{covered} / #{desc_total_overall} &middot; #{p}%</div>
                         </div>
                       </td>
                     </tr>
                   TR
                 end.join
                 %(
                   <h2>Description coverage by language</h2>
                   <table class="stats-table">#{desc_rows}</table>
                 ).strip
               else
                 ''
               end

  body = <<~HTML
    <h1>Native Game DB</h1>
    <p class="lead">A retro game database with first-class support for native scripts &mdash; the original written form of game titles in every non-Latin writing system (日本語, 한국어, 中文, …).</p>
    <p><strong>#{stats['total_games']} games</strong> across #{stats['platforms'].size} platforms.</p>
    <h2>Coverage by language</h2>
    #{overall_progress}
    <p class="target-note">Denominator for each language = retail ROMs in that language's home region (jp for 日本語, kr for 한국어, cn/tw/hk for 中文). Numerator = entries carrying at least one title in that language, native script or Latin transliteration.</p>

    <h2>Browse by platform</h2>
    <ul class="platform-grid">#{rows}</ul>

    #{desc_table}

    <h2>Title languages</h2>
    <table class="stats-table">#{langs_rows}</table>

    <h2>Title scripts (ISO 15924)</h2>
    <table class="stats-table">#{scripts_rows}</table>

    <h2>API</h2>
    <p>Every page on this site has a JSON counterpart under <code>/api/#{API_VERSION}/</code>. See the <a href="docs/schema.html">schema specification</a> for details.</p>
    <ul>
      <li><a href="api/v1/platforms.json"><code>/api/v1/platforms.json</code></a></li>
      <li><a href="api/v1/stats.json"><code>/api/v1/stats.json</code></a></li>
      <li><code>/api/v1/{platform}.json</code></li>
      <li><code>/api/v1/games/{platform}/{id}.json</code></li>
      <li><a href="search-index/all.json"><code>/search-index/all.json</code></a></li>
    </ul>

    <h2>Want to help?</h2>
    <p>Most entries are auto-imported from Wikidata and need human verification. See the <a href="docs/contributing.html">contributing guide</a>.</p>
  HTML

  layout(title: 'Native Game DB', body: body, root_rel: '')
end

def render_progress_bar(named, total, pct, size: :lg, lang_label: nil)
  return '' unless total && total.positive?
  width = pct.clamp(0, 100)
  klass = size == :sm ? 'progress progress-sm' : 'progress'
  suffix = lang_label ? " #{lang_label} titles" : ''
  label = size == :sm ?
    %(<strong>#{named}</strong>&thinsp;/&thinsp;#{total} &middot; #{pct}%) :
    %(<strong>#{named}</strong> / #{total} retail releases have#{suffix} &middot; <strong>#{pct}%</strong>)
  %(
    <div class="#{klass}" title="#{named} / #{total}#{lang_label ? " (#{lang_label})" : ''}">
      <div class="progress-bar" style="width: #{width}%"></div>
      <div class="progress-label">#{label}</div>
    </div>
  ).strip
end

def render_lang_progress_stack(by_lang, size: :lg)
  return '' if by_lang.nil? || by_lang.empty?
  bars = NATIVE_LANGS.map do |lang, spec|
    row = by_lang[lang]
    next nil unless row && row['total']&.positive?
    render_progress_bar(
      row['named'], row['total'], row['percent'],
      size: size,
      lang_label: "#{spec[:name]} (#{lang})"
    )
  end.compact
  bars.join("\n")
end

def render_description_table(desc_total, desc_by_lang)
  return '' unless desc_total && desc_total.positive?
  rows = desc_by_lang.map do |lang, covered|
    pct = (covered * 100.0 / desc_total).round(1)
    width = pct.clamp(0, 100)
    <<~TR
      <tr>
        <th><code>#{h(lang)}</code></th>
        <td style="width: 60%">
          <div class="progress progress-sm">
            <div class="progress-bar" style="width: #{width}%"></div>
            <div class="progress-label">#{covered} / #{desc_total} &middot; #{pct}%</div>
          </div>
        </td>
      </tr>
    TR
  end.join
  %(
    <h2>Description coverage by language</h2>
    <table class="stats-table">#{rows}</table>
  )
end

def render_platform_page(platform_id, name, games, progress = nil, _target = nil) # rubocop:disable Metrics/ParameterLists
  rows = games.map { |g|
    title    = display_title(g)
    en       = primary_title(g, 'en')
    date     = g['first_release_date']
    # Prefer the boxart whose region matches the entry's first retail
    # ROM region, so a JP-only game shows its JP box and a US-only game
    # shows its US box — without hard-coding any regional preference.
    boxarts  = (g['media'] || []).select { |m| m['kind'] == 'boxart' }
    primary_region = (g['roms'] || []).first&.dig('region')
    boxart   = boxarts.find { |m| m['region'] == primary_region } || boxarts.first
    extra    = []

    # Show every non-English native-language title with its script badge,
    # not just Japanese.
    NATIVE_LANGS.each_key do |lang|
      t = primary_title(g, lang)
      next unless t && t['text'] != title
      extra << %(<span class="badge">#{h(t['script'])}</span> #{h(t['text'])})
    end
    extra << %(EN: #{h(en['text'])}) if en && en['text'] != title
    extra << %(#{h(date)}) if date

    thumb = boxart ? %(<div class="thumb"><img src="#{h(boxart['url'])}" alt="" loading="lazy"></div>) : ''

    <<~LI
      <li class="game-list-item">
        #{thumb}
        <div class="info">
          <a href="../../games/#{platform_id}/#{g['id']}.html"><strong>#{h(title)}</strong></a>
          <div class="meta">#{extra.join(' &middot; ')}</div>
        </div>
      </li>
    LI
  }.join

  progress_html = progress ? render_lang_progress_stack(progress['by_lang'], size: :lg) : ''

  coverage_heading = progress_html.empty? ? '' : '<h2>Coverage by language</h2>'

  desc_html = progress ? render_description_table(progress['desc_total'], progress['desc_by_lang']) : ''

  body = <<~HTML
    <h1>#{h(name)}</h1>
    <p class="lead">#{games.size} games in the database &middot; <a href="../../api/v1/#{platform_id}.json">JSON API</a></p>
    #{coverage_heading}
    #{progress_html}
    #{desc_html}
    <ul class="game-list">#{rows}</ul>
  HTML

  layout(title: name, body: body, root_rel: '../../')
end

def render_media_section(game)
  media = game['media'] || []
  return '' if media.empty?

  # Group media by kind, show every regional variant inside each group
  # (not just one). Order: boxart, boxart_back, titlescreen, screenshot, etc.
  order = %w[boxart boxart_back titlescreen screenshot cartridge disc logo]
  grouped = order.map { |k| [k, media.select { |m| m['kind'] == k }] }.to_h
  extras = media.reject { |m| order.include?(m['kind']) }.group_by { |m| m['kind'] }
  grouped.merge!(extras)

  sections = grouped.map do |kind, entries|
    next nil if entries.empty?
    kind_label = kind.to_s.tr('_', ' ')

    # Dedup identical URLs (same image referenced twice) and sort so
    # regional variants are stable: jp, us, eu, others, then null.
    seen = {}
    deduped = entries.each_with_object([]) do |m, acc|
      key = m['url']
      next if seen[key]
      seen[key] = true
      acc << m
    end
    region_order = %w[jp us eu kr cn tw hk au br]
    sorted = deduped.sort_by do |m|
      r = m['region']
      [region_order.index(r) || (r.nil? ? 99 : 50), r.to_s]
    end

    figs = sorted.map do |m|
      region = m['region']
      caption = region ? "#{kind_label} (#{region})" : kind_label
      %(<figure><img src="#{h(m['url'])}" alt="#{h(caption)}" loading="lazy"><figcaption>#{h(caption)}</figcaption></figure>)
    end.join

    figs
  end.compact.join

  %(<h2>Media</h2><div class="media-grid">#{sections}</div>)
end

def render_rom_section(game)
  roms = game['roms'] || []
  return '' if roms.empty?

  rows = roms.map { |r|
    hashes = %w[crc32 md5 sha1 sha256]
              .map { |h| r[h] ? "<code>#{h}: #{r[h][0, 16]}#{r[h].size > 16 ? '…' : ''}</code>" : nil }
              .compact.join('<br>')
    <<~TR
      <tr>
        <td><code>#{h(r['name'])}</code></td>
        <td>#{h(r['region'] || '')}</td>
        <td><code>#{h(r['serial'] || '')}</code></td>
        <td>#{r['size'] ? "#{r['size']} B" : ''}</td>
        <td>#{hashes}</td>
      </tr>
    TR
  }.join

  <<~HTML
    <h2>ROMs (#{roms.size})</h2>
    <details>
    <summary>Show No-Intro ROM metadata</summary>
    <table>
      <thead><tr><th>Name</th><th>Region</th><th>Serial</th><th>Size</th><th>Hashes</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    </details>
  HTML
end

# Group descriptions by language and render them as CSS-only tabs.
# Every <label for="..."> targets a sibling <input type="radio">, and
# CSS rules further down show the matching .tab-panel by id. Because
# each game page has a single tab group we embed the game id into
# every element id to keep radio names unique across the whole site.
LANG_LABEL = {
  'en' => 'English', 'ja' => '日本語', 'ko' => '한국어',
  'zh' => '中文',     'fr' => 'Français', 'es' => 'Español',
  'de' => 'Deutsch',  'it' => 'Italiano', 'pt' => 'Português',
  'ru' => 'Русский'
}.freeze
LANG_ORDER = %w[en ja ko zh fr es de it pt ru].freeze

def render_description_tabs(game)
  descs = game['descriptions'] || []
  return '' if descs.empty?

  by_lang = Hash.new { |h, k| h[k] = [] }
  descs.each { |d| by_lang[d['lang']] << d }
  langs = LANG_ORDER.select { |l| by_lang.key?(l) } +
          (by_lang.keys - LANG_ORDER)

  return '' if langs.empty?

  group = "desc-#{game['id']}"

  # Radios come first so that the general-sibling selector (~) can
  # reach the panels that come later inside the same container.
  inputs = langs.each_with_index.map do |lang, i|
    checked = i.zero? ? ' checked' : ''
    %(<input type="radio" name="#{group}" id="#{group}-#{lang}"#{checked}>)
  end.join

  labels = langs.map do |lang|
    label = LANG_LABEL[lang] || lang
    %(<label for="#{group}-#{lang}">#{h(label)} <code>#{h(lang)}</code></label>)
  end.join

  panels = langs.map do |lang|
    items = by_lang[lang].map do |d|
      src = d['source'] ? %(<span class="src">source: #{h(d['source'])}</span>) : ''
      %(<p lang="#{h(lang)}">#{src}#{h(d['text'])}</p>)
    end.join
    %(<div class="tab-panel" id="panel-#{group}-#{lang}">#{items}</div>)
  end.join

  rules = langs.map do |lang|
    "##{group}-#{lang}:checked ~ .tab-panels ##{['panel', group, lang].join('-')} { display: block; }\n##{group}-#{lang}:checked ~ .tab-labels label[for=\"#{group}-#{lang}\"] { background: var(--bg); color: var(--fg); border-bottom: 2px solid var(--accent); font-weight: 600; }"
  end.join("\n")

  <<~HTML
    <div class="desc-tabs">
      #{inputs}
      <div class="tab-labels">#{labels}</div>
      <div class="tab-panels">#{panels}</div>
      <style>#{rules}</style>
    </div>
  HTML
end

def render_game_page(game)
  platform_id   = game['platform']
  platform_name = PLATFORMS[platform_id] || platform_id
  title         = display_title(game)

  title_rows = game['titles'].map { |t|
    verified_html = t['verified'] ?
      %(<span class="verified-yes">✓ verified</span>) :
      %(<span class="verified-no">unverified</span>)
    <<~TR
      <tr>
        <td><strong lang="#{h(t['lang'])}">#{h(t['text'])}</strong></td>
        <td><code>#{h(t['lang'])}</code></td>
        <td><code>#{h(t['script'])}</code></td>
        <td>#{h(t['region'])}</td>
        <td>#{h(t['form'])}</td>
        <td>#{h(t['source'])}</td>
        <td>#{verified_html}</td>
      </tr>
    TR
  }.join

  meta_rows = []
  if game['first_release_date']
    meta_rows << "<tr><th>First release</th><td>#{h(game['first_release_date'])}</td></tr>"
  end
  if game['developers']&.any?
    meta_rows << "<tr><th>Developers</th><td>#{game['developers'].map { |d| h(d) }.join(', ')}</td></tr>"
  end
  if game['publishers']&.any?
    meta_rows << "<tr><th>Publishers</th><td>#{game['publishers'].map { |d| h(d) }.join(', ')}</td></tr>"
  end
  if game['genres']&.any?
    meta_rows << "<tr><th>Genres</th><td>#{game['genres'].map { |d| h(d) }.join(', ')}</td></tr>"
  end
  meta_rows << "<tr><th>Category</th><td>#{h(game['category'])}</td></tr>"
  meta_rows << "<tr><th>Platform</th><td><a href=\"../../platforms/#{platform_id}/\">#{h(platform_name)}</a></td></tr>"

  external_rows = (game['external_ids'] || {}).map { |source, id|
    link = case source
           when 'wikidata'  then %(<a href="https://www.wikidata.org/wiki/#{h(id)}">#{h(id)}</a>)
           when 'igdb'      then %(<a href="https://www.igdb.com/games/#{h(id)}">#{h(id)}</a>)
           when 'mobygames' then %(<a href="https://www.mobygames.com/game/#{h(id)}">#{h(id)}</a>)
           else h(id.to_s)
           end
    "<tr><th><code>#{h(source)}</code></th><td>#{link}</td></tr>"
  }.join

  description_html = render_description_tabs(game)

  body = <<~HTML
    <p><a href="../../platforms/#{platform_id}/">&laquo; #{h(platform_name)}</a></p>
    <h1 lang="#{h((game['titles'].find { |t| t['text'] == title } || {})['lang'] || 'en')}">#{h(title)}</h1>

    #{render_media_section(game)}

    <h2>Titles</h2>
    <table>
      <thead>
        <tr><th>Text</th><th>Lang</th><th>Script</th><th>Region</th><th>Form</th><th>Source</th><th>Verified</th></tr>
      </thead>
      <tbody>#{title_rows}</tbody>
    </table>

    #{description_html.empty? ? '' : "<h2>Description</h2>#{description_html}"}

    <h2>Metadata</h2>
    <table>#{meta_rows.join}</table>

    #{external_rows.empty? ? '' : "<h2>External IDs</h2><table>#{external_rows}</table>"}

    #{render_rom_section(game)}

    <h2>Raw JSON</h2>
    <p><a href="../../api/v1/games/#{platform_id}/#{game['id']}.json">/api/v1/games/#{platform_id}/#{game['id']}.json</a></p>
  HTML

  layout(title: title, body: body, root_rel: '../../')
end

def render_contributing
  body = <<~HTML
    <h1>Contributing data</h1>
    <p class="lead">Native Game DB lives in a public GitHub repository. All data lands as JSON files under <code>data/games/{platform}/</code>, one game per file. Anyone with a GitHub account can propose changes via pull request or issue.</p>

    <h2>The fast path: open an issue</h2>
    <p>If you just want to add or correct one game, the easiest path is to open a GitHub issue. We will eventually provide a structured issue template (Phase 4 in the roadmap), but for now a free-form issue with the following information is enough:</p>
    <ul>
      <li>Platform identifier (e.g. <code>gb</code>, <code>fc</code>, <code>sfc</code>)</li>
      <li>The slug of the game if it already exists, or the canonical English name otherwise</li>
      <li>The native-script title(s) you want to add or correct, with their language and script (see the <a href="schema.html">schema spec</a>)</li>
      <li>The source of the information (your own physical copy, a screenshot of the in-game title screen, an authoritative reference, etc.)</li>
    </ul>
    <p><a href="https://github.com/retronian/native-game-db/issues/new">Open a new issue</a></p>

    <h2>The thorough path: open a pull request</h2>
    <ol>
      <li>Fork <a href="https://github.com/retronian/native-game-db">retronian/native-game-db</a> on GitHub.</li>
      <li>For a new game, create a new file at <code>data/games/{platform}/{slug}.json</code>. The slug must match the file name and must be lowercase ASCII with hyphens.</li>
      <li>Make sure the file conforms to <a href="schema.html"><code>schema/game.schema.json</code></a>.</li>
      <li>Open a pull request describing the source of the data and whether you have verified it against a primary source (title screen, original packaging).</li>
    </ol>

    <h2>Verifying titles</h2>
    <p>Most existing entries were imported from Wikidata and have <code>"verified": false</code>. We use <code>verified: true</code> only when the title has been confirmed against a primary source &mdash; ideally the in-game title logo, the original boxart, or the printed manual. Wikipedia articles and other downstream databases do not count as primary sources.</p>
    <p>If you can confirm an existing title against a primary source, please open a pull request flipping <code>verified</code> from <code>false</code> to <code>true</code> and add a brief note in the PR description about how you verified it.</p>

    <h2>Style and conventions</h2>
    <ul>
      <li>One game per file. Do not pack multiple entries into a single file.</li>
      <li>The <code>id</code> field must equal the file name without the <code>.json</code> extension.</li>
      <li>Prefer the English (or romaji) form of the title for the slug. Use the Wikidata QID as a last resort.</li>
      <li>Add the <code>script</code> field to every <code>titles[]</code> entry. Use ISO 15924 codes (<code>Jpan</code>, <code>Hira</code>, <code>Kana</code>, <code>Hans</code>, <code>Hant</code>, <code>Hang</code>, <code>Latn</code>, etc.).</li>
      <li>Do not invent new <code>source</code> values. Stick to the enum defined in the schema.</li>
    </ul>

    <h2>What not to contribute</h2>
    <ul>
      <li>Cover art and other binary assets &mdash; we do not host them yet.</li>
      <li>ROM data, hashes, or anything that could be used to identify a copyrighted file (planned for a separate <code>roms</code> layer).</li>
      <li>Translations of native-script titles into Latin script that are not the romaji form printed on the original packaging or the in-game logo.</li>
    </ul>
  HTML

  layout(title: 'Contributing', body: body, root_rel: '../')
end

def render_schema_doc
  body = <<~HTML
    <h1>Schema specification</h1>
    <p class="lead">If you want to write a scraper that emits Native Game DB-compatible JSON, this page is the contract. The authoritative machine-readable definition lives at <a href="https://github.com/retronian/native-game-db/blob/main/schema/game.schema.json"><code>schema/game.schema.json</code></a> (JSON Schema Draft 2020-12).</p>

    <h2>File layout</h2>
    <p>One JSON file per game, stored at:</p>
    <pre><code>data/games/{platform}/{id}.json</code></pre>
    <p>The <code>id</code> field inside the file must equal the file name without the <code>.json</code> extension. The <code>platform</code> field must equal the directory name.</p>

    <h2>Top-level fields</h2>
    <table>
      <thead><tr><th>Field</th><th>Type</th><th>Required</th><th>Description</th></tr></thead>
      <tbody>
        <tr><td><code>id</code></td><td>string</td><td>yes</td><td>Slug, lowercase ASCII with hyphens. Matches the file name.</td></tr>
        <tr><td><code>platform</code></td><td>string (enum)</td><td>yes</td><td>Platform identifier. See the <a href="../">home page</a> for the current list.</td></tr>
        <tr><td><code>category</code></td><td>string (enum)</td><td>no</td><td><code>main_game</code> (default), <code>dlc</code>, <code>expansion</code>, <code>bundle</code>, <code>remake</code>, <code>remaster</code>, <code>port</code>, <code>compilation</code>.</td></tr>
        <tr><td><code>first_release_date</code></td><td>string</td><td>no</td><td>ISO 8601 date or partial date (<code>YYYY</code>, <code>YYYY-MM</code>, <code>YYYY-MM-DD</code>).</td></tr>
        <tr><td><code>titles</code></td><td>array</td><td>yes</td><td>At least one entry. See below.</td></tr>
        <tr><td><code>descriptions</code></td><td>array</td><td>no</td><td>Multilingual descriptions, see below.</td></tr>
        <tr><td><code>developers</code></td><td>string[]</td><td>no</td><td>Developer slugs.</td></tr>
        <tr><td><code>publishers</code></td><td>string[]</td><td>no</td><td>Publisher slugs.</td></tr>
        <tr><td><code>genres</code></td><td>string[]</td><td>no</td><td>Genre slugs.</td></tr>
        <tr><td><code>external_ids</code></td><td>object</td><td>no</td><td>Cross-references to other databases.</td></tr>
      </tbody>
    </table>

    <h2>Title objects (the core)</h2>
    <p>Every entry in <code>titles[]</code> has these fields:</p>
    <table>
      <thead><tr><th>Field</th><th>Type</th><th>Required</th><th>Description</th></tr></thead>
      <tbody>
        <tr><td><code>text</code></td><td>string</td><td>yes</td><td>The title as it appears.</td></tr>
        <tr><td><code>lang</code></td><td>string</td><td>yes</td><td>ISO 639-1 language code: <code>ja</code>, <code>en</code>, <code>ko</code>, <code>zh</code>, <code>es</code>, <code>fr</code>, <code>de</code>, <code>it</code>, etc.</td></tr>
        <tr><td><code>script</code></td><td>string (enum)</td><td>yes</td><td><strong>ISO 15924 script code.</strong> See the table below.</td></tr>
        <tr><td><code>region</code></td><td>string</td><td>no</td><td>ISO 3166-1 alpha-2 country code, lowercase.</td></tr>
        <tr><td><code>form</code></td><td>string (enum)</td><td>no</td><td><code>official</code>, <code>boxart</code>, <code>ingame_logo</code>, <code>manual</code>, <code>romaji_transliteration</code>, <code>alternate</code>.</td></tr>
        <tr><td><code>source</code></td><td>string (enum)</td><td>no</td><td><code>wikidata</code>, <code>igdb</code>, <code>mobygames</code>, <code>screenscraper</code>, <code>no_intro</code>, <code>community</code>, <code>manual</code>.</td></tr>
        <tr><td><code>verified</code></td><td>boolean</td><td>no</td><td>Whether the entry has been confirmed against a primary source.</td></tr>
      </tbody>
    </table>

    <h2>The <code>script</code> field (ISO 15924)</h2>
    <p>This is what makes Native Game DB different from every other game DB. The language tag <code>ja</code> alone cannot tell katakana-only titles apart from kanji-mixed titles, but in retro game metadata that distinction often matters. The valid values are:</p>
    <table>
      <thead><tr><th>Code</th><th>Meaning</th><th>Example</th></tr></thead>
      <tbody>
        <tr><td><code>Jpan</code></td><td>Japanese with kanji and kana mixed</td><td>星のカービィ</td></tr>
        <tr><td><code>Hira</code></td><td>Japanese, hiragana only</td><td>くにおくん</td></tr>
        <tr><td><code>Kana</code></td><td>Japanese, katakana only</td><td>スーパーマリオブラザーズ</td></tr>
        <tr><td><code>Hang</code></td><td>Korean hangul</td><td>별의 커비</td></tr>
        <tr><td><code>Hans</code></td><td>Chinese, simplified</td><td>星之卡比</td></tr>
        <tr><td><code>Hant</code></td><td>Chinese, traditional</td><td>星之卡比</td></tr>
        <tr><td><code>Latn</code></td><td>Latin script</td><td>Kirby's Dream Land</td></tr>
        <tr><td><code>Cyrl</code></td><td>Cyrillic</td><td>Кирби</td></tr>
        <tr><td><code>Arab</code>, <code>Hebr</code>, <code>Thai</code></td><td>Arabic, Hebrew, Thai</td><td>&mdash;</td></tr>
        <tr><td><code>Zyyy</code></td><td>Undetermined</td><td>Use as last resort.</td></tr>
      </tbody>
    </table>

    <h2>Description objects</h2>
    <p>Each entry in <code>descriptions[]</code> has <code>text</code> (string), <code>lang</code> (ISO 639-1), and an optional <code>source</code> (same enum as titles).</p>

    <h2>External IDs</h2>
    <p><code>external_ids</code> is an object mapping a source name to its identifier. Recognized keys:</p>
    <ul>
      <li><code>wikidata</code> &mdash; Wikidata QID, e.g. <code>"Q1064715"</code></li>
      <li><code>igdb</code> &mdash; IGDB game ID (integer)</li>
      <li><code>mobygames</code> &mdash; MobyGames game ID (integer)</li>
      <li><code>screenscraper</code> &mdash; ScreenScraper.fr jeu ID (integer)</li>
      <li><code>thegamesdb</code> &mdash; TheGamesDB game ID (integer)</li>
      <li><code>openvgdb</code> &mdash; OpenVGDB release ID (integer)</li>
    </ul>

    <h2>Example</h2>
    <pre><code>#{h(<<~JSON)}</code></pre>
      {
        "id": "hoshi-no-kirby",
        "platform": "gb",
        "category": "main_game",
        "first_release_date": "1992-04-27",
        "titles": [
          {
            "text": "星のカービィ",
            "lang": "ja",
            "script": "Jpan",
            "region": "jp",
            "form": "boxart",
            "source": "wikidata",
            "verified": true
          },
          {
            "text": "Kirby's Dream Land",
            "lang": "en",
            "script": "Latn",
            "region": "us",
            "form": "official",
            "source": "wikidata",
            "verified": true
          }
        ],
        "developers": ["hal-laboratory"],
        "publishers": ["nintendo"],
        "genres": ["platformer"],
        "external_ids": {
          "wikidata": "Q1064715",
          "igdb": 1083
        }
      }
    JSON

    <h2>API endpoints</h2>
    <p>The static API mirrors the on-disk layout:</p>
    <ul>
      <li><code>/api/v1/platforms.json</code> &mdash; list of platforms with counts</li>
      <li><code>/api/v1/stats.json</code> &mdash; aggregate statistics</li>
      <li><code>/api/v1/{platform}.json</code> &mdash; all games on a platform, as a JSON array</li>
      <li><code>/api/v1/games/{platform}/{id}.json</code> &mdash; a single game entry</li>
      <li><code>/search-index/all.json</code> &mdash; minimal index for client-side search</li>
    </ul>
    <p>Everything is cache-friendly static JSON. There is no rate limiting and no authentication.</p>
  HTML

  layout(title: 'Schema specification', body: body, root_rel: '../')
end

# ---------------------------------------------------------------------------
# Main

def main
  puts '=== native-game-db build ==='
  puts

  FileUtils.rm_rf(DIST)
  FileUtils.mkdir_p(API)
  FileUtils.mkdir_p(INDEX_DIR)

  all_games = []
  platforms_meta = []
  script_totals = Hash.new(0)
  language_totals = Hash.new(0)

  PLATFORMS.each do |platform_id, name|
    games = load_games(platform_id)
    puts "  #{platform_id.ljust(4)} #{games.size.to_s.rjust(5)} games"

    write_json(File.join(API, "#{platform_id}.json"), games)

    games.each do |g|
      write_json(File.join(API, 'games', platform_id, "#{g['id']}.json"), g)
      write_html(File.join(DIST, 'games', platform_id, "#{g['id']}.html"),
                 render_game_page(g))

      g['titles'].each do |t|
        script_totals[t['script']] += 1 if t['script']
        language_totals[t['lang']] += 1 if t['lang']
      end
    end

    # Coverage per native-language: for each language (ja/ko/zh), the
    # denominator is "games released in that language's regions with a
    # retail ROM" and the numerator is "those with at least one title
    # in that language". `native` counts only ISO 15924 native scripts
    # (Latin transliterations are recorded but not counted as native).
    by_lang = NATIVE_LANGS.each_with_object({}) do |(lang, spec), acc|
      released = games.count { |g| released_in_any?(g, spec[:regions]) }
      named    = games.count { |g| released_in_any?(g, spec[:regions]) && has_title_in_lang?(g, lang) }
      native   = games.count { |g| released_in_any?(g, spec[:regions]) && has_native_script_title?(g, lang) }
      pct      = released.positive? ? (named * 100.0 / released).round(1) : nil
      acc[lang] = { 'total' => released, 'named' => named, 'native' => native, 'percent' => pct }
    end

    # Description language coverage. For each tracked language we
    # count how many games on this platform have at least one
    # descriptions[] entry in that language.
    desc_total = games.size
    desc_langs = %w[en ja ko zh fr es de it]
    desc_by_lang = desc_langs.to_h do |lang|
      hit = games.count { |g| (g['descriptions'] || []).any? { |d| d['lang'] == lang && !d['text'].to_s.strip.empty? } }
      [lang, hit]
    end

    progress = {
      'by_lang'      => by_lang,
      'desc_total'   => desc_total,
      'desc_by_lang' => desc_by_lang
    }

    write_html(File.join(DIST, 'platforms', platform_id, 'index.html'),
               render_platform_page(platform_id, name, games, progress, nil))

    pmeta = {
      'id'    => platform_id,
      'name'  => name,
      'count' => games.size,
      'url'   => "/api/#{API_VERSION}/#{platform_id}.json"
    }.merge(progress)
    platforms_meta << pmeta

    all_games.concat(games)
  end

  write_pretty_json(File.join(API, 'platforms.json'), {
    'version'   => API_VERSION,
    'platforms' => platforms_meta
  })

  stats = {
    'version'      => API_VERSION,
    'total_games'  => all_games.size,
    'platforms'    => platforms_meta.map { |p| [p['id'], p['count']] }.to_h,
    'languages'    => language_totals.sort_by { |_, v| -v }.to_h,
    'scripts'      => script_totals.sort_by { |_, v| -v }.to_h,
    'generated_at' => Time.now.utc.iso8601
  }
  write_pretty_json(File.join(API, 'stats.json'), stats)

  write_json(File.join(INDEX_DIR, 'all.json'), all_games.map { |g| search_doc(g) })

  # CSS
  FileUtils.mkdir_p(File.join(DIST, 'assets'))
  File.write(File.join(DIST, 'assets', 'style.css'), CSS)

  # Top-level pages
  write_html(File.join(DIST, 'index.html'), render_landing(stats, platforms_meta))
  write_html(File.join(DIST, 'docs', 'contributing.html'), render_contributing)
  write_html(File.join(DIST, 'docs', 'schema.html'), render_schema_doc)

  # GitHub Pages custom domain
  File.write(File.join(DIST, 'CNAME'), "#{CNAME}\n")

  puts
  puts '=== Build summary ==='
  puts "  total games: #{stats['total_games']}"
  puts "  languages:   #{stats['languages']}"
  puts "  scripts:     #{stats['scripts']}"

  files = Dir.glob(File.join(DIST, '**', '*')).select { |f| File.file?(f) }
  total_size = files.sum { |f| File.size(f) }
  puts "  total size:  #{(total_size / 1024.0 / 1024.0).round(2)} MB"
  puts "  files:       #{files.size}"
end

main if __FILE__ == $PROGRAM_NAME
