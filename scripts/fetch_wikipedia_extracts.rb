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
USER_AGENT = 'native-game-db/0.1 (https://gamedb.retronian.com)'

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1 vb ngp gg ms].freeze

SPARQL_BATCH  = 500
EXTRACT_BATCH = 20   # MediaWiki extracts API hard limit
EXTRACT_CHARS = 1200 # how much of the intro to keep

# ---------- SPARQL: QID -> en article title ----------

def sparql_qid_to_enwiki(qids)
  return {} if qids.empty?
  values = qids.map { |q| "wd:#{q}" }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?articleName WHERE {
      VALUES ?item { #{values} }
      ?article schema:about ?item ;
               schema:isPartOf <https://en.wikipedia.org/> ;
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
      warn '    sparql returned non-JSON, skipping batch'
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

def fetch_extracts(article_titles)
  return {} if article_titles.empty?
  args = ['curl', '-sL', '-G',
          '--max-time', '45',
          '-H', "User-Agent: #{USER_AGENT}",
          'https://en.wikipedia.org/w/api.php',
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
    warn '    extracts returned non-JSON, skipping batch'
    return {}
  end

  redirects = {}
  (data.dig('query', 'redirects') || []).each { |r| redirects[r['from']] = r['to'] }

  by_title = {}
  (data.dig('query', 'pages') || []).each do |p|
    next unless p['title']
    ex = p['extract']
    next if ex.nil? || ex.strip.empty?
    # Trim to roughly EXTRACT_CHARS
    text = ex.strip[0, EXTRACT_CHARS]
    by_title[p['title']] = text
  end

  # Map back from requested title (pre-redirect) to final extract.
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

def already_has_extract?(game)
  (game['descriptions'] || []).any? { |d| d['source'] == 'wikipedia_en' }
end

def first_en_title(game)
  game['titles'].find { |t| t['lang'] == 'en' && t['script'] == 'Latn' }&.dig('text')
end

def main
  options = { dry_run: false, platform: nil, limit: nil, by_title: false, skip_qid: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/fetch_wikipedia_extracts.rb [--platform ID] [--dry-run] [--by-title]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
    opts.on('--limit N', Integer) { |n| options[:limit] = n }
    opts.on('--by-title', 'skip QID phase, look up en.wiki by English title') { options[:by_title] = true }
    opts.on('--skip-qid', 'alias for --by-title') { options[:by_title] = true }
  end.parse!

  platforms = options[:platform] ? [options[:platform]] : PLATFORMS
  puts "=== fetch_wikipedia_extracts#{options[:by_title] ? ' (by title)' : ''} ==="

  platforms.each do |pf|
    entries = []
    each_platform_game(pf) do |path, game|
      next if already_has_extract?(game)
      if options[:by_title]
        title = first_en_title(game)
        next if title.nil? || title.empty?
        entries << { path: path, game: game, en_title: title }
      else
        qid = game.dig('external_ids', 'wikidata')
        next unless qid
        entries << { path: path, game: game, qid: qid }
      end
    end
    entries = entries.first(options[:limit]) if options[:limit]
    puts "  #{pf}: #{entries.size} candidate entries"
    next if entries.empty?

    totals = Hash.new(0)

    articles_to_fetch = nil
    entry_to_article = {}

    if options[:by_title]
      # Use the entry's English title directly as the Wikipedia page title.
      entries.each { |e| entry_to_article[e] = e[:en_title] }
      articles_to_fetch = entries.map { |e| e[:en_title] }.uniq
    else
      # Phase 1: QID -> en article title (via SPARQL sitelink)
      qid_to_article = {}
      entries.each_slice(SPARQL_BATCH).with_index do |batch, i|
        qids = batch.map { |e| e[:qid] }
        got = sparql_qid_to_enwiki(qids)
        qid_to_article.merge!(got)
        puts "    sparql batch #{i + 1}: #{qids.size} -> #{got.size} articles"
        sleep 0.4
      end
      entries.each { |e| entry_to_article[e] = qid_to_article[e[:qid]] }
      articles_to_fetch = qid_to_article.values.uniq
    end

    # Phase 2: article title -> extract
    article_to_extract = {}
    articles_to_fetch.each_slice(EXTRACT_BATCH).with_index do |batch, i|
      got = fetch_extracts(batch)
      article_to_extract.merge!(got)
      if ((i + 1) % 20).zero?
        puts "    extracts batch #{i + 1}/#{(articles_to_fetch.size / EXTRACT_BATCH.to_f).ceil}: running total #{article_to_extract.size}"
      end
      sleep 0.3
    end
    puts "    extracted intros: #{article_to_extract.size}"

    # Phase 3: write back
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
      descs << { 'text' => extract, 'lang' => 'en', 'source' => 'wikipedia_en' }
      totals[:added] += 1
      File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n") unless options[:dry_run]
    end

    puts "    totals: #{totals}"
  end
end

main if __FILE__ == $PROGRAM_NAME
