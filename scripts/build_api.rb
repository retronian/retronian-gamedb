#!/usr/bin/env ruby
# frozen_string_literal: true

# data/games/{platform}/*.json を集約し、GitHub Pages 配信用の
# 静的 JSON API を dist/ 配下に生成する。
#
# 出力:
#   dist/index.html               簡易ランディングページ
#   dist/api/v1/platforms.json    プラットフォーム一覧
#   dist/api/v1/stats.json        統計情報
#   dist/api/v1/{platform}.json   プラットフォーム別ゲーム一覧
#   dist/api/v1/games/{platform}/{id}.json  個別ゲーム（コピー）
#   dist/search-index/all.json    クライアントサイド検索用インデックス
#
# 使用方法:
#   ruby scripts/build_api.rb

require 'json'
require 'fileutils'
require 'time'

ROOT  = File.expand_path('..', __dir__)
SRC   = File.join(ROOT, 'data', 'games')
DIST  = File.join(ROOT, 'dist')
API   = File.join(DIST, 'api', 'v1')
INDEX = File.join(DIST, 'search-index')
API_VERSION = 'v1'

# プラットフォーム定義（fetch_wikidata.rb と一致）
PLATFORMS = {
  'fc'  => 'Famicom / NES',
  'sfc' => 'Super Famicom / SNES',
  'gb'  => 'Game Boy',
  'gbc' => 'Game Boy Color',
  'gba' => 'Game Boy Advance',
  'md'  => 'Mega Drive / Genesis',
  'pce' => 'PC Engine / TurboGrafx-16',
  'n64' => 'Nintendo 64',
  'nds' => 'Nintendo DS'
}.freeze

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

def primary_title(game, lang)
  game['titles'].find { |t| t['lang'] == lang }
end

def search_doc(game)
  ja = primary_title(game, 'ja')
  en = primary_title(game, 'en')

  doc = {
    'id'       => game['id'],
    'platform' => game['platform']
  }
  doc['ja'] = ja['text']        if ja
  doc['ja_script'] = ja['script'] if ja
  doc['en'] = en['text']        if en
  doc['date'] = game['first_release_date'] if game['first_release_date']
  doc
end

def main
  puts "=== native-game-db build ==="
  puts

  FileUtils.rm_rf(DIST)
  FileUtils.mkdir_p(API)
  FileUtils.mkdir_p(INDEX)

  all_games = []
  platforms_meta = []
  script_totals = Hash.new(0)

  PLATFORMS.each do |platform_id, name|
    games = load_games(platform_id)
    puts "  #{platform_id.ljust(4)} #{games.size.to_s.rjust(5)} games"

    # プラットフォーム別マージJSON
    write_json(File.join(API, "#{platform_id}.json"), games)

    # 個別ゲームファイルを dist 配下にコピー
    games.each do |g|
      write_json(File.join(API, 'games', platform_id, "#{g['id']}.json"), g)
    end

    # 統計
    games.each do |g|
      ja = primary_title(g, 'ja')
      script_totals[ja['script']] += 1 if ja
    end

    platforms_meta << {
      'id'    => platform_id,
      'name'  => name,
      'count' => games.size,
      'url'   => "/api/#{API_VERSION}/#{platform_id}.json"
    }

    all_games.concat(games)
  end

  # platforms.json
  write_pretty_json(File.join(API, 'platforms.json'), {
    'version'   => API_VERSION,
    'platforms' => platforms_meta
  })

  # stats.json
  stats = {
    'version'      => API_VERSION,
    'total_games'  => all_games.size,
    'platforms'    => platforms_meta.map { |p| [p['id'], p['count']] }.to_h,
    'ja_scripts'   => script_totals.sort_by { |_, v| -v }.to_h,
    'generated_at' => Time.now.utc.iso8601
  }
  write_pretty_json(File.join(API, 'stats.json'), stats)

  # search-index/all.json (クライアントサイド検索用、最小フィールド)
  write_json(File.join(INDEX, 'all.json'),
             all_games.map { |g| search_doc(g) })

  # 簡易ランディング
  write_landing_page(stats)

  puts
  puts "=== 出力サマリー ==="
  puts "  合計ゲーム: #{stats['total_games']}"
  puts "  scripts: #{stats['ja_scripts']}"

  total_size = Dir.glob(File.join(DIST, '**', '*')).select { |f| File.file?(f) }.sum { |f| File.size(f) }
  puts "  dist 総サイズ: #{(total_size / 1024.0 / 1024.0).round(2)} MB"
  puts "  ファイル数: #{Dir.glob(File.join(DIST, '**', '*')).count { |f| File.file?(f) }}"
end

def write_landing_page(stats)
  rows = stats['platforms'].map { |id, count|
    name = PLATFORMS[id]
    %(<li><a href="api/v1/#{id}.json"><code>#{id}</code></a> #{name} — #{count} games</li>)
  }.join("\n")

  scripts = stats['ja_scripts'].map { |k, v| "<li><code>#{k}</code>: #{v}</li>" }.join("\n")

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Native Game DB</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 2em auto; padding: 0 1em; line-height: 1.6; color: #222; }
        code { background: #f4f4f4; padding: 0.1em 0.4em; border-radius: 3px; }
        h1 { border-bottom: 2px solid #222; padding-bottom: 0.3em; }
        ul { padding-left: 1.4em; }
        a { color: #0366d6; }
      </style>
    </head>
    <body>
      <h1>Native Game DB</h1>
      <p>レトロゲームのネイティブスクリプト（日本語等）対応ゲームデータベース。</p>
      <p><strong>Total: #{stats['total_games']} games</strong></p>

      <h2>Platforms</h2>
      <ul>
        #{rows}
      </ul>

      <h2>Japanese title scripts (ISO 15924)</h2>
      <ul>
        #{scripts}
      </ul>

      <h2>API endpoints</h2>
      <ul>
        <li><a href="api/v1/platforms.json"><code>/api/v1/platforms.json</code></a></li>
        <li><a href="api/v1/stats.json"><code>/api/v1/stats.json</code></a></li>
        <li><code>/api/v1/{platform}.json</code> — プラットフォーム別ゲーム一覧</li>
        <li><code>/api/v1/games/{platform}/{id}.json</code> — 個別ゲーム</li>
        <li><a href="search-index/all.json"><code>/search-index/all.json</code></a> — 検索用</li>
      </ul>

      <p><a href="https://github.com/retronian/native-game-db">GitHub</a></p>
    </body>
    </html>
  HTML

  FileUtils.mkdir_p(DIST)
  File.write(File.join(DIST, 'index.html'), html)
end

main if __FILE__ == $PROGRAM_NAME
