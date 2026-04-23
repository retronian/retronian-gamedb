#!/usr/bin/env ruby
# frozen_string_literal: true

# Pull English Wikipedia intro paragraphs into descriptions[].
#
# Flow:
#   1. For every game that has an external_ids.wikidata QID, ask
#      the Wikidata SPARQL endpoint for the corresponding en.wikipedia
#      article title via its sitelink.
#   2. Hit en.wikipedia.org action=query prop=extracts explaintext=1
#      exintro=1 in batches of 20 article titles to grab the intro
#      paragraph.
#   3. Append a descriptions[] entry with
#      { lang: en, source: wikipedia_en }.
#
# Usage:
#   ruby scripts/fetch_wikipedia_extracts.rb               # all platforms
#   ruby scripts/fetch_wikipedia_extracts.rb --platform gb
#   ruby scripts/fetch_wikipedia_extracts.rb --dry-run
#   ruby scripts/fetch_wikipedia_extracts.rb --platform ps1 --limit 100

require 'json'
require 'open3'
require 'optparse'
require 'tempfile'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
USER_AGENT = 'retronian-gamedb/0.1 (https://gamedb.retronian.com)'

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1].freeze

SPARQL_BATCH  = 500
EXTRACT_BATCH = 20   # MediaWiki extracts API hard limit
EXTRACT_CHARS = 1200 # how much of the intro to keep

LANG_LIST = %w[en ja ko zh fr es de it pt ru].freeze

# ---------- SPARQL: QID -> {lang}.wikipedia article title ----------

def sparql_qid_to_article(qids, lang)
  return {} if qids.empty?
  values = qids.map { |q| "wd:#{q}" }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?articleName WHERE {
      VALUES ?item { #{values} }
      ?article schema:about ?item ;
               schema:isPartOf <https://#{lang}.wikipedia.org/> ;
               schema:name ?articleName .
    }
  SPARQL

  Tempfile.create(['sparql', '.rq']) do |f|
    f.write(query)
    f.flush
    out, _ = Open3.capture2('curl', '-s', '-X', 'POST',
                            '--max-time', '60',
                            'https://query.wikidata.org/sparql?format=json',
                            '-H', 'Content-Type: application/sparql-query',
                            '-H', 'Accept: application/sparql-results+json',
                            '-H', "User-Agent: #{USER_AGENT}",
                            '--data-binary', "@#{f.path}")
    begin
      data = JSON.parse(out)
    rescue JSON::ParserError
      warn "    sparql[#{lang}] returned non-JSON, skipping batch"
      return {}
    end
    map = {}
    (data.dig('results', 'bindings') || []).each do |b|
      qid = b.dig('item', 'value')&.split('/')&.last
      name = b.dig('articleName', 'value')
      map[qid] = name if qid && name
    end
    map
  end
end

# ---------- MediaWiki extracts API ----------

def fetch_extracts(article_titles, lang)
  return {} if article_titles.empty?
  args = ['curl', '-sL', '-G',
          '--max-time', '45',
          '-H', "User-Agent: #{USER_AGENT}",
          "https://#{lang}.wikipedia.org/w/api.php",
          '--data-urlencode', 'action=query',
          '--data-urlencode', 'prop=extracts',
          '--data-urlencode', 'exintro=1',
          '--data-urlencode', 'explaintext=1',
          '--data-urlencode', 'redirects=1',
          '--data-urlencode', "titles=#{article_titles.join('|')}",
          '--data-urlencode', 'format=json',
          '--data-urlencode', 'formatversion=2']
  out, _ = Open3.capture2(*args)
  begin
    data = JSON.parse(out)
  rescue JSON::ParserError
    warn "    extracts[#{lang}] returned non-JSON, skipping batch"
    return {}
  end

  redirects = {}
  (data.dig('query', 'redirects') || []).each { |r| redirects[r['from']] = r['to'] }

  by_title = {}
  (data.dig('query', 'pages') || []).each do |p|
    next unless p['title']
    ex = p['extract']
    next if ex.nil? || ex.strip.empty?
    text = ex.strip[0, EXTRACT_CHARS]
    by_title[p['title']] = text
  end

  map = {}
  article_titles.each do |req|
    final = redirects[req] || req
    ex = by_title[final]
    map[req] = ex if ex
  end
  map
end

# ---------- Main ----------

def each_platform_game(platform_id)
  Dir.glob(File.join(SRC, platform_id, '*.json')).sort.each do |path|
    yield path, JSON.parse(File.read(path))
  end
end

def already_has_extract?(game, lang)
  src = "wikipedia_#{lang}"
  (game['descriptions'] || []).any? { |d| d['source'] == src }
end

def title_for_lang(game, lang)
  # Prefer a ja title for ja.wiki lookups (and so on), fall back to en.
  pref = game['titles'].find { |t| t['lang'] == lang && t['script'] != 'Latn' }
  pref ||= game['titles'].find { |t| t['lang'] == lang }
  pref ||= game['titles'].find { |t| t['lang'] == 'en' && t['script'] == 'Latn' }
  pref&.dig('text')
end

def process_platform(pf, lang, by_title:, dry_run:, limit:)
  entries = []
  each_platform_game(pf) do |path, game|
    next if already_has_extract?(game, lang)
    if by_title
      title = title_for_lang(game, lang)
      next if title.nil? || title.empty?
      entries << { path: path, game: game, title: title }
    else
      qid = game.dig('external_ids', 'wikidata')
      next unless qid
      entries << { path: path, game: game, qid: qid }
    end
  end
  entries = entries.first(limit) if limit
  puts "  #{pf}/#{lang}: #{entries.size} candidate entries"
  return if entries.empty?

  totals = Hash.new(0)
  entry_to_article = {}

  if by_title
    entries.each { |e| entry_to_article[e] = e[:title] }
    articles_to_fetch = entries.map { |e| e[:title] }.uniq
  else
    qid_to_article = {}
    entries.each_slice(SPARQL_BATCH).with_index do |batch, i|
      qids = batch.map { |e| e[:qid] }
      got = sparql_qid_to_article(qids, lang)
      qid_to_article.merge!(got)
      puts "    sparql[#{lang}] batch #{i + 1}: #{qids.size} -> #{got.size} articles"
      sleep 0.4
    end
    entries.each { |e| entry_to_article[e] = qid_to_article[e[:qid]] }
    articles_to_fetch = qid_to_article.values.uniq
  end

  article_to_extract = {}
  articles_to_fetch.each_slice(EXTRACT_BATCH).with_index do |batch, i|
    got = fetch_extracts(batch, lang)
    article_to_extract.merge!(got)
    if ((i + 1) % 20).zero?
      puts "    extracts[#{lang}] batch #{i + 1}/#{(articles_to_fetch.size / EXTRACT_BATCH.to_f).ceil}: running total #{article_to_extract.size}"
    end
    sleep 0.3
  end
  puts "    #{lang} intros: #{article_to_extract.size}"

  entries.each do |entry|
    article = entry_to_article[entry]
    unless article
      totals[:no_article] += 1
      next
    end
    extract = article_to_extract[article]
    unless extract
      totals[:no_extract] += 1
      next
    end

    descs = entry[:game]['descriptions'] ||= []
    descs << { 'text' => extract, 'lang' => lang, 'source' => "wikipedia_#{lang}" }
    totals[:added] += 1
    File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n") unless dry_run
  end

  puts "    totals[#{lang}]: #{totals}"
end

def main
  options = { dry_run: false, platform: nil, limit: nil, by_title: false, langs: %w[en] }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/fetch_wikipedia_extracts.rb [--platform ID] [--lang en,ja,...] [--dry-run]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
    opts.on('--limit N', Integer) { |n| options[:limit] = n }
    opts.on('--by-title', 'skip QID phase, look up by title from game entry') { options[:by_title] = true }
    opts.on('--lang LIST', 'comma-separated language codes, or "all"') { |l| options[:langs] = l == 'all' ? LANG_LIST : l.split(',') }
  end.parse!

  platforms = options[:platform] ? [options[:platform]] : PLATFORMS
  puts "=== fetch_wikipedia_extracts (langs=#{options[:langs].join(',')}#{options[:by_title] ? ', by-title' : ''}) ==="

  options[:langs].each do |lang|
    platforms.each do |pf|
      process_platform(pf, lang, by_title: options[:by_title], dry_run: options[:dry_run], limit: options[:limit])
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
