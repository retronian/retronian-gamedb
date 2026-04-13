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
  'ps1' => 'PlayStation',
  'vb'  => 'Virtual Boy',
  'ngp' => 'Neo Geo Pocket',
  'gg'  => 'Game Gear',
  'ms'  => 'Sega Master System'
}.freeze

# Expected Japanese release count per platform, used for the coverage
# progress bars. Loaded lazily so a missing file just disables the bars.
def platform_targets
  @platform_targets ||= begin
    path = File.join(ROOT, 'data', 'platform_targets.json')
    return {} unless File.exist?(path)
    JSON.parse(File.read(path)).dig('targets') || {}
  end
end

# A game counts as "released in Japan" when we have a No-Intro ROM
# tagged region=jp that is *not* a prototype, beta, pirate dump,
# unlicensed release, homebrew or BIOS. Only retail releases count.
#
# Wikidata and IGDB labels would happily assign ja tags to games that
# never shipped in Japan (localized Wikipedia article titles etc), so
# we rely on No-Intro's region tagging as ground truth and strip the
# non-retail bucket explicitly.
NON_RETAIL_ROM_RE = /\((?:Proto|Possible Proto|Beta|Unl|Pirate|Sample|Demo|Hack|Aftermarket|Homebrew)\)/i.freeze

def japanese_release?(game)
  return false if game['id'].to_s.start_with?('bios-')
  return false if (game['category'] || '') == 'bios'
  (game['roms'] || []).any? do |r|
    next false unless r['region'] == 'jp'
    next false if r['name'].to_s =~ NON_RETAIL_ROM_RE
    true
  end
end

# Does the entry carry at least one Japanese-script title? This is the
# "we have native-script metadata" signal. Latin script ja entries
# (romaji transliterations) don't count — those are ASCII reverts of
# the real Japanese name and are already covered by the No-Intro name.
def has_native_japanese_title?(game)
  game['titles'].any? do |t|
    t['lang'] == 'ja' && %w[Jpan Hira Kana].include?(t['script'])
  end
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
  primary_title(game, 'en')&.dig('text') ||
    primary_title(game, 'ja')&.dig('text') ||
    game['titles'].first&.dig('text') ||
    game['id']
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
      <link rel="stylesheet" href="#{root_rel}assets/style.css">
    </head>
    <body>
      <header class="site-header">
        <a class="brand" href="#{root_rel}">Native Game DB</a>
        <nav>
          <a href="#{root_rel}">Home</a>
          <a href="#{root_rel}docs/schema.html">Schema</a>
          <a href="#{root_rel}docs/contributing.html">Contributing</a>
          <a href="https://github.com/retronian/native-game-db">GitHub</a>
        </nav>
      </header>
      <main>
        #{body}
      </main>
      <footer class="site-footer">
        <p>Native Game DB &middot; <a href="https://github.com/retronian/native-game-db">retronian/native-game-db</a></p>
      </footer>
    </body>
    </html>
  HTML
end

CSS = <<~CSS
  :root {
    --fg: #1c1c1e;
    --muted: #555;
    --bg: #fff;
    --accent: #0366d6;
    --line: #e6e6e6;
    --code-bg: #f5f5f7;
  }
  .media-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: 0.8em;
    margin: 1em 0;
  }
  .media-grid figure {
    margin: 0;
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: 0.5em;
    background: var(--bg);
  }
  .media-grid img {
    width: 100%;
    height: auto;
    display: block;
    image-rendering: pixelated;
  }
  .media-grid figcaption {
    font-size: 0.8em;
    color: var(--muted);
    margin-top: 0.3em;
    text-align: center;
  }
  .game-list-item { display: flex; gap: 0.8em; }
  .game-list-item .thumb { flex: 0 0 80px; }
  .game-list-item .thumb img { width: 80px; height: auto; border-radius: 3px; }
  .game-list-item .info { flex: 1; min-width: 0; }
  .progress {
    position: relative;
    background: var(--code-bg);
    border-radius: 4px;
    height: 20px;
    overflow: hidden;
    margin: 1em 0;
    border: 1px solid var(--line);
  }
  .progress-bar {
    position: absolute;
    top: 0; left: 0; bottom: 0;
    background: linear-gradient(90deg, #22c55e 0%, #16a34a 100%);
    transition: width 0.4s ease;
  }
  .progress-label {
    position: relative;
    z-index: 1;
    font-size: 0.82em;
    color: #111;
    text-align: center;
    line-height: 20px;
    text-shadow: 0 0 2px rgba(255,255,255,0.6);
  }
  .progress-sm { height: 14px; margin: 0.4em 0 0; }
  .progress-sm .progress-label { line-height: 14px; font-size: 0.72em; }
  .target-note { color: var(--muted); font-size: 0.85em; margin-top: -0.5em; }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Hiragino Sans", "Noto Sans CJK JP", sans-serif;
    color: var(--fg);
    background: var(--bg);
    margin: 0;
    line-height: 1.6;
  }
  main {
    max-width: 760px;
    margin: 0 auto;
    padding: 1.5em 1.2em 4em;
  }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  code, pre {
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    background: var(--code-bg);
    border-radius: 4px;
  }
  code { padding: 0.1em 0.4em; }
  pre {
    padding: 1em;
    overflow-x: auto;
    font-size: 0.9em;
    line-height: 1.5;
  }
  h1 { font-size: 1.8em; margin-top: 0.5em; }
  h2 { margin-top: 2em; border-bottom: 1px solid var(--line); padding-bottom: 0.3em; }
  h3 { margin-top: 1.6em; }
  .lead { color: var(--muted); font-size: 1.05em; }
  .site-header {
    border-bottom: 1px solid var(--line);
    padding: 0.8em 1.2em;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 1em;
    max-width: 760px;
    margin: 0 auto;
  }
  .site-header .brand {
    font-weight: 700;
    font-size: 1.05em;
    color: var(--fg);
    margin-right: auto;
  }
  .site-header nav { display: flex; gap: 1em; flex-wrap: wrap; }
  .site-footer {
    border-top: 1px solid var(--line);
    padding: 1.5em 1.2em;
    text-align: center;
    color: var(--muted);
    font-size: 0.9em;
  }
  .platform-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 0.8em;
    list-style: none;
    padding: 0;
  }
  .platform-grid li {
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 0.8em 1em;
  }
  .platform-grid .count { color: var(--muted); font-size: 0.9em; }
  table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 1em;
    font-size: 0.95em;
  }
  th, td {
    text-align: left;
    padding: 0.55em 0.6em;
    border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  th { font-weight: 600; background: var(--code-bg); }
  .game-list { list-style: none; padding: 0; }
  .game-list li {
    border-bottom: 1px solid var(--line);
    padding: 0.6em 0.2em;
  }
  .game-list .meta { color: var(--muted); font-size: 0.85em; }
  .badge {
    display: inline-block;
    background: var(--code-bg);
    border-radius: 3px;
    padding: 0.05em 0.4em;
    font-size: 0.85em;
    color: var(--muted);
    font-family: ui-monospace, monospace;
  }
  .verified-yes { color: #1e7f1e; }
  .verified-no { color: #888; }
  .stats-table th { width: 30%; }
CSS

# ---------------------------------------------------------------------------
# HTML pages

def render_landing(stats, platforms_meta)
  rows = platforms_meta.map { |p|
    bar = render_progress_bar(p['jp_named'], p['jp_total'], p['jp_percent'], size: :sm)
    <<~LI
      <li>
        <a href="platforms/#{p['id']}/"><strong>#{h(p['name'])}</strong></a>
        <div class="count">#{p['count']} games &middot; <code>#{p['id']}</code></div>
        #{bar}
      </li>
    LI
  }.join

  scripts_rows = stats['scripts'].map { |k, v|
    "<tr><th><code>#{h(k)}</code></th><td>#{v}</td></tr>"
  }.join

  langs_rows = stats['languages'].map { |k, v|
    "<tr><th><code>#{h(k)}</code></th><td>#{v}</td></tr>"
  }.join

  tracked = platforms_meta.select { |p| p['jp_total']&.positive? }
  overall_progress = if tracked.any?
                       total_named    = tracked.sum { |p| p['jp_named'] }
                       total_released = tracked.sum { |p| p['jp_total'] }
                       pct = (total_named * 100.0 / total_released).round(1)
                       width = pct.clamp(0, 100)
                       %(
                         <div class="progress">
                           <div class="progress-bar" style="width: #{width}%"></div>
                           <div class="progress-label"><strong>#{total_named}</strong> / #{total_released} Japanese releases have a native-script title &middot; <strong>#{pct}%</strong></div>
                         </div>
                         <p class="target-note">Help us reach 100% — every missing entry is a real retro game whose Japanese title is not in the database yet.</p>
                       ).strip
                     else
                       ''
                     end

  # Overall descriptions coverage by language.
  desc_total_overall = platforms_meta.sum { |p| p['desc_total'] || 0 }
  desc_by_lang_overall = Hash.new(0)
  platforms_meta.each do |p|
    (p['desc_by_lang'] || {}).each { |lang, n| desc_by_lang_overall[lang] += n }
  end

  desc_table = if desc_total_overall.positive?
                 rows = desc_by_lang_overall.sort_by { |_, v| -v }.map do |lang, covered|
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
                   <table class="stats-table">#{rows}</table>
                 ).strip
               else
                 ''
               end

  body = <<~HTML
    <h1>Native Game DB</h1>
    <p class="lead">A retro game database with first-class support for native scripts &mdash; the original written form of game titles in Japanese, Korean, Chinese, and other non-Latin writing systems.</p>
    <p><strong>#{stats['total_games']} games</strong> across #{stats['platforms'].size} platforms.</p>
    #{overall_progress}

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

def render_progress_bar(named, total, pct, size: :lg)
  return '' unless total && total.positive?
  width = pct.clamp(0, 100)
  klass = size == :sm ? 'progress progress-sm' : 'progress'
  label = size == :sm ?
    %(<strong>#{named}</strong>&thinsp;/&thinsp;#{total} &middot; #{pct}%) :
    %(<strong>#{named}</strong> / #{total} Japanese releases have a native-script title &middot; <strong>#{pct}%</strong>)
  %(
    <div class="#{klass}" title="#{named} named out of #{total} Japanese releases">
      <div class="progress-bar" style="width: #{width}%"></div>
      <div class="progress-label">#{label}</div>
    </div>
  ).strip
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

def render_platform_page(platform_id, name, games, progress = nil, target = nil) # rubocop:disable Metrics/ParameterLists
  rows = games.map { |g|
    title    = display_title(g)
    ja       = primary_title(g, 'ja')
    en       = primary_title(g, 'en')
    date     = g['first_release_date']
    boxart   = (g['media'] || []).find { |m| m['kind'] == 'boxart' }
    extra    = []
    extra << %(<span class="badge">#{h(ja['script'])}</span> #{h(ja['text'])}) if ja
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

  progress_html = if progress && progress['jp_total']&.positive?
                    render_progress_bar(progress['jp_named'], progress['jp_total'], progress['jp_percent'])
                  else
                    ''
                  end

  official_note = if progress && progress['official']
                    source_link = target && target['source_url'] ? %( (<a href="#{h(target['source_url'])}">source</a>)) : ''
                    %(<p class="target-note">Official Japanese release count: <strong>#{progress['official']}</strong>#{source_link}. #{progress['jp_named_db'] && progress['jp_named_db'] > progress['jp_named'] ? "The DB actually carries #{progress['jp_named_db']} Japanese-titled entries, including overseas editions." : ''}</p>)
                  else
                    ''
                  end

  desc_html = progress ? render_description_table(progress['desc_total'], progress['desc_by_lang']) : ''

  body = <<~HTML
    <h1>#{h(name)}</h1>
    <p class="lead">#{games.size} games in the database &middot; <a href="../../api/v1/#{platform_id}.json">JSON API</a></p>
    #{progress_html}
    #{official_note}
    #{desc_html}
    <ul class="game-list">#{rows}</ul>
  HTML

  layout(title: name, body: body, root_rel: '../../')
end

def render_media_section(game)
  media = game['media'] || []
  return '' if media.empty?

  # Pick at most one thumbnail per kind to keep the page tidy.
  picks = {}
  media.each { |m| picks[m['kind']] ||= m }

  # Order: boxart, titlescreen, screenshot
  order = %w[boxart titlescreen screenshot cartridge disc logo]
  sorted = order.map { |k| picks[k] }.compact + picks.reject { |k, _| order.include?(k) }.values

  figs = sorted.map { |m|
    label = m['kind'].sub('_', ' ')
    %(<figure><img src="#{h(m['url'])}" alt="#{h(label)}" loading="lazy"><figcaption>#{h(label)}</figcaption></figure>)
  }.join

  %(<h2>Media</h2><div class="media-grid">#{figs}</div>)
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

  description_html = (game['descriptions'] || []).map { |d|
    "<p lang=\"#{h(d['lang'])}\">#{h(d['text'])}</p>"
  }.join

  body = <<~HTML
    <p><a href="../../platforms/#{platform_id}/">&laquo; #{h(platform_name)}</a></p>
    <h1 lang="#{h(primary_title(game, 'ja')&.dig('lang') || 'en')}">#{h(title)}</h1>

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

    jp_released_rom = games.count { |g| japanese_release?(g) }
    jp_named_all    = games.count { |g| has_native_japanese_title?(g) }
    target          = platform_targets[platform_id]
    official        = target && target['jp_total']

    # Denominator: official Nintendo/Sega figure when available,
    # otherwise fall back to the count of games with a jp ROM so the
    # bar still shows something for unsourced platforms.
    jp_total = official || jp_released_rom

    # Numerator: games on this platform that have at least one
    # native-script Japanese title, capped at the denominator so the
    # bar never exceeds 100%.
    jp_named = [jp_named_all, jp_total].min

    jp_percent = jp_total.positive? ? (jp_named * 100.0 / jp_total).round(1) : nil

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
      'jp_total'    => jp_total,
      'jp_named'    => jp_named,
      'jp_named_db' => jp_named_all,
      'jp_percent'  => jp_percent,
      'official'    => official,
      'desc_total'  => desc_total,
      'desc_by_lang' => desc_by_lang
    }

    write_html(File.join(DIST, 'platforms', platform_id, 'index.html'),
               render_platform_page(platform_id, name, games, progress, target))

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
