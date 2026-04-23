#!/usr/bin/env ruby
# frozen_string_literal: true

# After purge_igdb_content.rb removes every IGDB-sourced title,
# thousands of games end up with an empty titles[] array. This script
# refills them from license-friendly upstream sources, in priority
# order:
#
#   1. external_ids.wikidata -> Wikidata rdfs:label in ja and en
#      (Wikidata is CC0, fully free to redistribute).
#   2. external_ids.igdb     -> reverse-lookup the IGDB id on Wikidata
#      via wdt:P5794 to find the same item, then take rdfs:label.
#   3. roms[].name           -> use the No-Intro base name as an English
#      title (No-Intro names are factual identifiers, not editorial
#      content, and are widely treated as freely usable).
#
# Whatever survives at the end with no title gets reported but not
# auto-deleted; we want to look at the leftover list before pruning.
#
# Usage:
#   ruby scripts/rescue_orphaned_titles.rb               # all platforms
#   ruby scripts/rescue_orphaned_titles.rb --platform fc
#   ruby scripts/rescue_orphaned_titles.rb --dry-run

require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require_relative 'lib/script_detector'
require_relative 'lib/slug'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
USER_AGENT = 'retronian-gamedb/0.1 (https://gamedb.retronian.com)'

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1].freeze

SPARQL_BATCH = 200

# ---------- helpers ----------

def each_orphan(platform_id)
  Dir.glob(File.join(SRC, platform_id, '*.json')).sort.each do |path|
    game = JSON.parse(File.read(path))
    next unless game['titles'].nil? || game['titles'].empty?
    yield path, game
  end
end

def write_back(path, game, dry_run)
  File.write(path, JSON.pretty_generate(game) + "\n") unless dry_run
end

def wikidata_sparql(query)
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
    JSON.parse(out)
  rescue StandardError => e
    warn "    sparql error: #{e.message}"
    { 'results' => { 'bindings' => [] } }
  end
end

def fetch_labels_by_qid(qids)
  return {} if qids.empty?
  values = qids.uniq.map { |q| "wd:#{q}" }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?jaLabel ?enLabel WHERE {
      VALUES ?item { #{values} }
      OPTIONAL { ?item rdfs:label ?jaLabel . FILTER(LANG(?jaLabel) = "ja") }
      OPTIONAL { ?item rdfs:label ?enLabel . FILTER(LANG(?enLabel) = "en") }
    }
  SPARQL
  data = wikidata_sparql(query)
  map = {}
  (data.dig('results', 'bindings') || []).each do |b|
    qid = b.dig('item', 'value')&.split('/')&.last
    next unless qid
    map[qid] ||= {}
    map[qid][:ja] ||= b.dig('jaLabel', 'value')
    map[qid][:en] ||= b.dig('enLabel', 'value')
  end
  map
end

def fetch_labels_by_igdb(igdb_ids)
  return {} if igdb_ids.empty?
  values = igdb_ids.uniq.map { |id| %("#{id}") }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?igdbId ?jaLabel ?enLabel WHERE {
      VALUES ?igdbId { #{values} }
      ?item wdt:P5794 ?igdbId .
      OPTIONAL { ?item rdfs:label ?jaLabel . FILTER(LANG(?jaLabel) = "ja") }
      OPTIONAL { ?item rdfs:label ?enLabel . FILTER(LANG(?enLabel) = "en") }
    }
  SPARQL
  data = wikidata_sparql(query)
  map = {}
  (data.dig('results', 'bindings') || []).each do |b|
    igdb = b.dig('igdbId', 'value')
    qid  = b.dig('item', 'value')&.split('/')&.last
    next unless igdb && qid
    map[igdb.to_i] ||= { qid: qid }
    map[igdb.to_i][:ja] ||= b.dig('jaLabel', 'value')
    map[igdb.to_i][:en] ||= b.dig('enLabel', 'value')
  end
  map
end

def title_entry(text, lang, source, region: nil, form: 'official', verified: false)
  script = ScriptDetector.detect(text)
  e = {
    'text'     => text,
    'lang'     => lang,
    'script'   => script,
    'form'     => form,
    'source'   => source,
    'verified' => verified
  }
  e['region'] = region if region
  e
end

def strip_no_intro_suffixes(name)
  name.gsub(/\s*\([^)]*\)\s*/, ' ').strip
end

def fill_from_wikidata(game, labels)
  added = false
  if labels[:en]
    game['titles'] << title_entry(labels[:en], 'en', 'wikidata', region: 'us', verified: false)
    added = true
  end
  if labels[:ja]
    game['titles'] << title_entry(labels[:ja], 'ja', 'wikidata', region: 'jp', verified: false)
    added = true
  end
  added
end

def fill_from_no_intro(game)
  roms = game['roms'] || []
  return false if roms.empty?
  primary = roms.find { |r| r['region'] == 'jp' } || roms.first
  base = strip_no_intro_suffixes(primary['name'])
  return false if base.empty?
  game['titles'] << title_entry(base, 'en', 'no_intro', region: primary['region'], verified: false)
  game['external_ids'] ||= {}
  true
end

# ---------- main ----------

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  platforms = options[:platform] ? [options[:platform]] : PLATFORMS

  totals = Hash.new(0)
  still_orphan = []

  platforms.each do |pf|
    orphans = []
    each_orphan(pf) { |path, game| orphans << { path: path, game: game } }
    next if orphans.empty?
    puts "  #{pf}: #{orphans.size} orphans"

    # Phase 1: rescue via existing wikidata QID
    qid_to_orphan = {}
    orphans.each do |o|
      qid = o[:game].dig('external_ids', 'wikidata')
      next unless qid
      qid_to_orphan[qid] = o
    end

    qid_to_orphan.keys.each_slice(SPARQL_BATCH) do |batch|
      labels = fetch_labels_by_qid(batch)
      labels.each do |qid, l|
        o = qid_to_orphan[qid]
        next unless o
        if fill_from_wikidata(o[:game], l)
          write_back(o[:path], o[:game], options[:dry_run])
          totals[:rescued_via_wikidata] += 1
        end
      end
      sleep 0.5
    end

    # Re-collect orphans that are still empty.
    orphans = orphans.reject { |o| !o[:game]['titles'].empty? }

    # Phase 2: rescue via IGDB id reverse lookup on Wikidata
    igdb_to_orphan = {}
    orphans.each do |o|
      igdb_id = o[:game].dig('external_ids', 'igdb')
      next unless igdb_id
      igdb_to_orphan[igdb_id] = o
    end

    igdb_to_orphan.keys.each_slice(SPARQL_BATCH) do |batch|
      labels = fetch_labels_by_igdb(batch)
      labels.each do |id, l|
        o = igdb_to_orphan[id]
        next unless o
        if fill_from_wikidata(o[:game], l)
          # Also record the QID we just discovered.
          o[:game]['external_ids']['wikidata'] ||= l[:qid] if l[:qid]
          write_back(o[:path], o[:game], options[:dry_run])
          totals[:rescued_via_igdb_id] += 1
        end
      end
      sleep 0.5
    end

    orphans = orphans.reject { |o| !o[:game]['titles'].empty? }

    # Phase 3: rescue via No-Intro rom name
    orphans.each do |o|
      if fill_from_no_intro(o[:game])
        write_back(o[:path], o[:game], options[:dry_run])
        totals[:rescued_via_no_intro] += 1
      end
    end

    orphans = orphans.reject { |o| !o[:game]['titles'].empty? }
    still_orphan.concat(orphans.map { |o| o[:path] })
  end

  puts
  puts '=== Result ==='
  totals.each { |k, v| puts "  #{k}: #{v}" }
  puts "  still orphaned: #{still_orphan.size}"
  puts '  examples:'
  still_orphan.first(20).each { |p| puts "    #{p}" }
end

main if __FILE__ == $PROGRAM_NAME
