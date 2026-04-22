#!/usr/bin/env ruby
# frozen_string_literal: true

# For every game that still has an empty titles[] array after the
# IGDB purge and the no-intro rescue pass, ask Wikidata's
# wbsearchentities API to find a matching item by name.
#
# We seed the search query by un-slugifying the file's id
# ("kirbys-dream-land" -> "kirbys dream land") and then asking for
# the platform of the wikidata item (P400) to ensure we only attach
# matches that target the right platform.
#
# Successful matches get a Wikidata QID, an English label and a
# Japanese label appended as new titles[] entries (source: wikidata,
# CC0). The new QID is also written to external_ids.wikidata so
# subsequent passes (descriptions etc) can pick it up too.
#
# Usage:
#   ruby scripts/rescue_via_wikidata_search.rb
#   ruby scripts/rescue_via_wikidata_search.rb --platform fc --dry-run

require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require_relative 'lib/script_detector'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
USER_AGENT = 'native-game-db/0.1 (https://gamedb.retronian.com)'

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1].freeze

# native-game-db platform -> Wikidata QID(s) for the platform itself.
PLATFORM_QIDS = {
  'fc'  => %w[Q172742],
  'sfc' => %w[Q183259],
  'gb'  => %w[Q186437],
  'gbc' => %w[Q203992],
  'gba' => %w[Q188642],
  'md'  => %w[Q10676],
  'pce' => %w[Q1057377],
  'n64' => %w[Q184839],
  'nds' => %w[Q170323],
  'ps1' => %w[Q10677]
}.freeze

# ---------- helpers ----------

def each_orphan(platform_id)
  Dir.glob(File.join(SRC, platform_id, '*.json')).sort.each do |path|
    game = JSON.parse(File.read(path))
    next unless game['titles'].nil? || game['titles'].empty?
    yield path, game
  end
end

def unslugify(slug)
  slug.split('-').map { |w| w.empty? ? w : w[0].upcase + w[1..] }.join(' ')
end

def search_wikidata(query)
  args = ['curl', '-sL', '-G',
          '--max-time', '20',
          '-H', "User-Agent: #{USER_AGENT}",
          'https://www.wikidata.org/w/api.php',
          '--data-urlencode', 'action=wbsearchentities',
          '--data-urlencode', "search=#{query}",
          '--data-urlencode', 'language=en',
          '--data-urlencode', 'type=item',
          '--data-urlencode', 'limit=5',
          '--data-urlencode', 'format=json']
  out, _ = Open3.capture2(*args)
  begin
    data = JSON.parse(out)
    (data['search'] || []).map { |r| r['id'] }
  rescue StandardError
    []
  end
end

def filter_by_platform_and_get_labels(qids, platform_qids)
  return {} if qids.empty?
  values = qids.uniq.map { |q| "wd:#{q}" }.join(' ')
  pf_values = platform_qids.map { |q| "wd:#{q}" }.join(' ')
  query = <<~SPARQL
    SELECT ?item ?jaLabel ?enLabel WHERE {
      VALUES ?item { #{values} }
      VALUES ?platform { #{pf_values} }
      ?item wdt:P31 wd:Q7889 ;
            wdt:P400 ?platform .
      OPTIONAL { ?item rdfs:label ?jaLabel . FILTER(LANG(?jaLabel) = "ja") }
      OPTIONAL { ?item rdfs:label ?enLabel . FILTER(LANG(?enLabel) = "en") }
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
    data = JSON.parse(out)
    map = {}
    (data.dig('results', 'bindings') || []).each do |b|
      qid = b.dig('item', 'value')&.split('/')&.last
      next unless qid
      map[qid] ||= {}
      map[qid][:ja] ||= b.dig('jaLabel', 'value')
      map[qid][:en] ||= b.dig('enLabel', 'value')
    end
    map
  rescue StandardError => e
    warn "    sparql error: #{e.message}"
    {}
  end
end

def title_entry(text, lang, region: nil, form: 'official', verified: false)
  e = {
    'text'     => text,
    'lang'     => lang,
    'script'   => ScriptDetector.detect(text),
    'form'     => form,
    'source'   => 'wikidata',
    'verified' => verified
  }
  e['region'] = region if region
  e
end

# ---------- main ----------

def main
  options = { dry_run: false, platform: nil, limit: nil }
  OptionParser.new do |opts|
    opts.on('--dry-run')        { options[:dry_run] = true }
    opts.on('--platform ID')    { |p| options[:platform] = p }
    opts.on('--limit N', Integer) { |n| options[:limit] = n }
  end.parse!

  platforms = options[:platform] ? [options[:platform]] : PLATFORMS

  totals = Hash.new(0)
  platforms.each do |pf|
    pf_qids = PLATFORM_QIDS[pf] or next
    orphans = []
    each_orphan(pf) { |path, game| orphans << { path: path, game: game } }
    orphans = orphans.first(options[:limit]) if options[:limit]
    next if orphans.empty?
    puts "  #{pf}: #{orphans.size} orphans"

    orphans.each_with_index do |o, i|
      query = unslugify(o[:game]['id'])
      next if query.empty?

      candidate_qids = search_wikidata(query)
      sleep 0.2

      if candidate_qids.empty?
        totals[:no_search_hit] += 1
        next
      end

      labels = filter_by_platform_and_get_labels(candidate_qids, pf_qids)
      sleep 0.5

      # Pick the first candidate that survived the platform filter and
      # has at least one label.
      chosen_qid = nil
      chosen = nil
      candidate_qids.each do |q|
        l = labels[q]
        next unless l && (l[:en] || l[:ja])
        chosen_qid = q
        chosen = l
        break
      end

      unless chosen
        totals[:no_platform_match] += 1
        next
      end

      titles = []
      titles << title_entry(chosen[:en], 'en', region: 'us') if chosen[:en]
      titles << title_entry(chosen[:ja], 'ja', region: 'jp') if chosen[:ja]
      next if titles.empty?

      o[:game]['titles'] = titles
      o[:game]['external_ids'] ||= {}
      o[:game]['external_ids']['wikidata'] = chosen_qid

      File.write(o[:path], JSON.pretty_generate(o[:game]) + "\n") unless options[:dry_run]
      totals[:rescued] += 1

      puts "    #{i + 1}/#{orphans.size} rescued: #{o[:game]['id']} -> #{chosen_qid}" if (i + 1) % 100 == 0
    end
  end

  puts
  puts '=== Result ==='
  totals.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
