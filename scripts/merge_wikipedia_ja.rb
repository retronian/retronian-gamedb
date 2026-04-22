#!/usr/bin/env ruby
# frozen_string_literal: true

# Extract Japanese titles from a Wikipedia JP platform list and merge
# them into native-game-db.
#
# The flow:
#   1. Fetch the wikitext of the platform list page via MediaWiki API.
#   2. Extract every wikilink [[target]] or [[target|display]] that
#      lives inside a game title cell.
#   3. Resolve each ja.wikipedia article to its Wikidata item and
#      pick up the en label via one big SPARQL VALUES query.
#   4. For each (ja_title, en_label) pair, look the entry up in the
#      native-game-db index by English-title slug and append a
#      Japanese title (source: wikipedia_ja, verified: true).
#
# Usage:
#   ruby scripts/merge_wikipedia_ja.rb --platform pce
#   ruby scripts/merge_wikipedia_ja.rb --platform ps1 --dry-run

require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'tempfile'
require 'set'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
USER_AGENT = 'native-game-db/0.1 (https://gamedb.retronian.com)'

PLATFORM_PAGES = {
  'fc'  => 'ファミリーコンピュータのゲームタイトル一覧',
  'sfc' => 'スーパーファミコンのゲームタイトル一覧',
  'gb'  => 'ゲームボーイのゲームタイトル一覧',
  'gbc' => 'ゲームボーイカラーのゲームタイトル一覧',
  'gba' => 'ゲームボーイアドバンスのゲームタイトル一覧',
  'md'  => 'メガドライブのゲームタイトル一覧',
  'pce' => 'PCエンジンのゲームタイトル一覧',
  'n64' => 'NINTENDO64のゲームタイトル一覧',
  'nds' => 'ニンテンドーDSのゲームタイトル一覧',
  'ps1' => 'PlayStationのゲームタイトル一覧'
}.freeze

# Some platforms (nds, ps1) do not have a usable list page — the DB
# of titles lives in Wikipedia categories instead. Fall back to those
# when the list-page extractor returns nothing.
PLATFORM_CATEGORIES = {
  'fc'  => 'ファミリーコンピュータ用ソフト',
  'sfc' => 'スーパーファミコン用ソフト',
  'gb'  => 'ゲームボーイ用ソフト',
  'gbc' => 'ゲームボーイカラー用ソフト',
  'gba' => 'ゲームボーイアドバンス用ソフト',
  'md'  => 'メガドライブ用ソフト',
  'pce' => 'PCエンジン用ソフト',
  'n64' => 'NINTENDO64用ソフト',
  'nds' => 'ニンテンドーDS用ソフト',
  'ps1' => 'PlayStation用ソフト'
}.freeze

def fetch_category_members(category)
  members = []
  cmcontinue = nil
  loop do
    args = ['curl', '-sL', '-G',
            '-H', "User-Agent: #{USER_AGENT}",
            'https://ja.wikipedia.org/w/api.php',
            '--data-urlencode', 'action=query',
            '--data-urlencode', 'list=categorymembers',
            '--data-urlencode', "cmtitle=Category:#{category}",
            '--data-urlencode', 'cmtype=page',
            '--data-urlencode', 'cmlimit=500',
            '--data-urlencode', 'format=json']
    args += ['--data-urlencode', "cmcontinue=#{cmcontinue}"] if cmcontinue

    out, _ = Open3.capture2(*args)
    data = JSON.parse(out)
    (data.dig('query', 'categorymembers') || []).each { |m| members << m['title'] }
    cmcontinue = data.dig('continue', 'cmcontinue')
    break unless cmcontinue
    sleep 0.2
  end
  members
end

# ---------- MediaWiki API ----------

def fetch_wikitext(page)
  out, _ = Open3.capture2('curl', '-sL', '-G',
                          '-H', "User-Agent: #{USER_AGENT}",
                          'https://ja.wikipedia.org/w/api.php',
                          '--data-urlencode', 'action=parse',
                          '--data-urlencode', "page=#{page}",
                          '--data-urlencode', 'format=json',
                          '--data-urlencode', 'prop=wikitext')
  JSON.parse(out).dig('parse', 'wikitext', '*') || ''
end

# Resolve ja.wikipedia article titles to Wikidata QIDs via pageprops.
# Up to 50 titles per request (MediaWiki API limit). Returns
# { article_title => QID }.
def pageprops_to_qids(titles)
  map = {}
  titles.each_slice(50).with_index do |batch, i|
    args = ['curl', '-sL', '-G',
            '-H', "User-Agent: #{USER_AGENT}",
            'https://ja.wikipedia.org/w/api.php',
            '--data-urlencode', 'action=query',
            '--data-urlencode', "titles=#{batch.join('|')}",
            '--data-urlencode', 'prop=pageprops',
            '--data-urlencode', 'ppprop=wikibase_item',
            '--data-urlencode', 'redirects=1',
            '--data-urlencode', 'format=json']
    out, _ = Open3.capture2(*args)
    begin
      data = JSON.parse(out)
    rescue JSON::ParserError
      warn "  pageprops batch #{i + 1}: parse error"
      next
    end

    # Track redirects so we can map requested title -> final title.
    redirect_map = {}
    (data.dig('query', 'redirects') || []).each do |r|
      redirect_map[r['from']] = r['to']
    end

    # pages is a hash keyed by pageid. Each page has a "title" and optional "pageprops.wikibase_item".
    pages = data.dig('query', 'pages') || {}
    by_title = {}
    pages.each_value do |p|
      qid = p.dig('pageprops', 'wikibase_item')
      by_title[p['title']] = qid if qid
    end

    batch.each do |req|
      final = redirect_map[req] || req
      qid = by_title[final]
      map[req] = qid if qid
    end
    sleep 0.2
  end
  map
end

# ---------- wikitext parsing ----------

# Extract {(ja_display_text, wikipedia_article_name)} pairs from the
# wikitext. We only walk rows that live inside a "発売日 ... タイトル"
# table — i.e. the commercial release tables.
def extract_wikilinks(wikitext)
  pairs = []
  in_title_table = false

  wikitext.lines.each do |line|
    if line =~ /^!.*タイトル.*発売元/
      in_title_table = true
    elsif line =~ /\A\{\|/ && !in_title_table
      # entering a non-title table
    end

    next unless in_title_table
    next unless line.start_with?('|') || line.start_with?('!')

    # Strip disambiguating spans like <span style="display:none">し26</span>
    clean = line.gsub(/<span[^>]*>[^<]*<\/span>/, '')
    # Pull every [[link]] or [[link|display]]
    clean.scan(/\[\[([^\[\]|]+?)(?:\|([^\[\]]+?))?\]\]/).each do |target, display|
      next if target.nil? || target.empty?
      next if target.start_with?('File:', 'ファイル:', 'Category:', 'カテゴリ:')
      next if target.include?('発売日')
      display_text = (display || target).strip
      # Discard short display texts that are almost certainly not game titles
      next if display_text.empty?
      next if display_text.length > 120
      pairs << [display_text, target.strip]
    end
  end

  pairs.uniq
end

# ---------- SPARQL resolve ----------

def wikidata_sparql(query)
  Tempfile.create(['sparql', '.rq']) do |f|
    f.write(query)
    f.flush
    out, _ = Open3.capture2('curl', '-s', '-X', 'POST',
                            'https://query.wikidata.org/sparql?format=json',
                            '-H', 'Content-Type: application/sparql-query',
                            '-H', 'Accept: application/sparql-results+json',
                            '-H', "User-Agent: #{USER_AGENT}",
                            '--data-binary', "@#{f.path}")
    JSON.parse(out)
  end
rescue StandardError => e
  warn "sparql error: #{e.message}"
  { 'results' => { 'bindings' => [] } }
end

# Given a batch of Wikidata QIDs, return { QID => en_label }.
def resolve_english_labels(qids)
  return {} if qids.empty?

  values = qids.uniq.map { |q| "wd:#{q}" }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?enLabel WHERE {
      VALUES ?item { #{values} }
      ?item rdfs:label ?enLabel .
      FILTER(LANG(?enLabel) = "en")
    }
  SPARQL

  data = wikidata_sparql(query)
  map = {}
  (data.dig('results', 'bindings') || []).each do |b|
    qid = b.dig('item', 'value')&.split('/')&.last
    en  = b.dig('enLabel', 'value')
    map[qid] = en if qid && en
  end
  map
end

# ---------- Merge ----------

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

def add_title_if_new(titles, incoming)
  match = titles.find { |t| t['lang'] == incoming['lang'] && normalize(t['text']) == normalize(incoming['text']) }
  if match
    match['verified'] = true if incoming['verified'] && !match['verified']
    :duplicate
  else
    titles << incoming
    :added
  end
end

def merge_record(record, ja_title, dry_run:)
  incoming = {
    'text'     => ja_title,
    'lang'     => 'ja',
    'script'   => ScriptDetector.detect(ja_title),
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'wikipedia_ja',
    'verified' => true
  }
  result = add_title_if_new(record[:game]['titles'], incoming)
  File.write(record[:path], JSON.pretty_generate(record[:game]) + "\n") if !dry_run && result == :added
  result
end

# Build a QID -> record index from the slug index so we can match
# entries that already know their Wikidata QID even if their English
# title does not line up with Wikipedia's article title.
def build_qid_index(slug_index)
  qids = {}
  slug_index.values.uniq.each do |record|
    qid = record[:game].dig('external_ids', 'wikidata')
    qids[qid] = record if qid
  end
  qids
end

def create_new_entry(platform_id, ja, en, qid, dry_run:)
  slug = Slug.slugify(en || ja)
  return nil if slug.nil? || slug.empty?

  path = File.join(SRC, platform_id, "#{slug}.json")
  return nil if File.exist?(path)

  entry = {
    'id'       => slug,
    'platform' => platform_id,
    'category' => 'main_game',
    'titles'   => []
  }
  if en && !en.strip.empty?
    entry['titles'] << {
      'text'     => en,
      'lang'     => 'en',
      'script'   => ScriptDetector.detect(en),
      'region'   => 'us',
      'form'     => 'official',
      'source'   => 'wikipedia_ja',
      'verified' => false
    }
  end
  entry['titles'] << {
    'text'     => ja,
    'lang'     => 'ja',
    'script'   => ScriptDetector.detect(ja),
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'wikipedia_ja',
    'verified' => true
  }
  entry['external_ids'] = { 'wikidata' => qid } if qid

  unless dry_run
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(entry) + "\n")
  end
  { path: path, game: entry }
end

def main
  require 'fileutils'
  options = { dry_run: false, platform: nil, batch: 150, create: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_wikipedia_ja.rb --platform ID [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
    opts.on('--batch N', Integer, 'batch size for SPARQL VALUES') { |n| options[:batch] = n }
    opts.on('--create-missing', 'create new entries for QIDs not in the DB') { options[:create] = true }
  end.parse!

  pf = options[:platform] or abort 'usage: --platform ID'
  page = PLATFORM_PAGES[pf]
  category = PLATFORM_CATEGORIES[pf]

  by_article = {}

  # Try the list-page extractor first.
  if page
    puts "=== Wikipedia JP merge: #{pf} (#{page}) ==="
    wikitext = fetch_wikitext(page)
    puts "  wikitext chars: #{wikitext.length}"
    pairs = extract_wikilinks(wikitext)
    puts "  extracted wikilinks: #{pairs.size}"
    pairs.each do |display, article|
      by_article[article] ||= display
    end
  end

  # If the list page yielded nothing useful, fall back to Category
  # membership. Cat members are article titles without a display
  # alias, so we use the article title as both.
  if by_article.size < 50 && category
    puts "  falling back to Category:#{category}"
    members = fetch_category_members(category)
    puts "  category members: #{members.size}"
    members.each { |title| by_article[title] ||= title.sub(/\s*\([^)]+\)\z/, '') }
  end

  articles = by_article.keys
  puts "  unique articles: #{articles.size}"

  puts '  pageprops -> QID...'
  qid_map = pageprops_to_qids(articles)
  puts "  articles with QID: #{qid_map.size}"

  puts '  SPARQL -> en label...'
  en_map = {}
  qid_map.values.uniq.each_slice(options[:batch]).with_index do |batch, i|
    got = resolve_english_labels(batch)
    en_map.merge!(got)
    puts "    batch #{i + 1}: #{batch.size} asked, #{got.size} resolved (total #{en_map.size})"
    sleep 0.5
  end
  puts "  QIDs with en label: #{en_map.size}"

  index     = DbIndex.build(SRC, pf)
  qid_index = build_qid_index(index)
  stats = Hash.new(0)

  articles.each do |article|
    ja = by_article[article]
    qid = qid_map[article]

    # First try: Wikidata QID is a direct key.
    record = qid && qid_index[qid]

    # Second try: resolve via English label -> slug index.
    if record.nil? && qid
      en = en_map[qid]
      record = DbIndex.lookup(index, en) if en
    end

    if record.nil? && qid && options[:create]
      en = en_map[qid]
      new_rec = create_new_entry(pf, ja, en, qid, dry_run: options[:dry_run])
      if new_rec
        stats[:created] += 1
        next
      end
    end

    unless record
      stats[qid ? :unmatched : :no_qid] += 1
      next
    end

    stats[merge_record(record, ja, dry_run: options[:dry_run])] += 1
  end

  puts
  puts '=== Result ==='
  stats.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
