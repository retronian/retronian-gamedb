#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetch retro game metadata for a given platform from Wikidata SPARQL
# and emit native-game-db schema-compliant JSON files into
# data/games/{platform}/.
#
# Usage:
#   ruby scripts/fetch_wikidata.rb gb
#   ruby scripts/fetch_wikidata.rb fc --limit 50
#   ruby scripts/fetch_wikidata.rb sfc --dry-run

require 'json'
require 'fileutils'
require 'tempfile'
require 'optparse'
require_relative 'lib/script_detector'

WIKIDATA_ENDPOINT = 'https://query.wikidata.org/sparql'
ROOT       = File.expand_path('..', __dir__)
USER_AGENT = 'native-game-db/0.1 (https://github.com/retronian/native-game-db)'

# Platform identifier -> Wikidata platform QIDs (one or more).
# Platforms that have multiple distinct Wikidata entities (e.g. the
# Neo Geo Pocket vs its Color variant) list them all, because Wikidata
# tags games with P400 against whichever specific hardware revision the
# editor remembered.
PLATFORMS = {
  'fc'  => { qids: %w[Q172742],            name: 'Famicom / NES' },
  'sfc' => { qids: %w[Q183259],            name: 'Super Famicom / SNES' },
  'gb'  => { qids: %w[Q186437],            name: 'Game Boy' },
  'gbc' => { qids: %w[Q203992],            name: 'Game Boy Color' },
  'gba' => { qids: %w[Q188642],            name: 'Game Boy Advance' },
  'md'  => { qids: %w[Q10676],             name: 'Mega Drive / Genesis' },
  'pce' => { qids: %w[Q1057377],           name: 'PC Engine / TurboGrafx-16' },
  'n64' => { qids: %w[Q184839],            name: 'Nintendo 64' },
  'nds' => { qids: %w[Q170323],            name: 'Nintendo DS' },
  'ps1' => { qids: %w[Q10677],             name: 'PlayStation' }
}.freeze

# Languages we ask Wikidata for. Each entry maps the SPARQL variable name
# to the BCP 47 language tag and a default region code (ISO 3166 alpha-2).
#
# script:
#   nil  -> use ScriptDetector (e.g. Japanese can be Jpan/Hira/Kana)
#   else -> fixed ISO 15924 code
LANGUAGES = [
  { var: 'jaLabel',     lang: 'ja', tag: 'ja',      region: 'jp', script: nil    },
  { var: 'enLabel',     lang: 'en', tag: 'en',      region: 'us', script: 'Latn' },
  { var: 'koLabel',     lang: 'ko', tag: 'ko',      region: 'kr', script: 'Hang' },
  { var: 'zhHansLabel', lang: 'zh', tag: 'zh-hans', region: 'cn', script: 'Hans' },
  { var: 'zhHantLabel', lang: 'zh', tag: 'zh-hant', region: 'tw', script: 'Hant' },
  { var: 'esLabel',     lang: 'es', tag: 'es',      region: 'es', script: 'Latn' },
  { var: 'frLabel',     lang: 'fr', tag: 'fr',      region: 'fr', script: 'Latn' },
  { var: 'deLabel',     lang: 'de', tag: 'de',      region: 'de', script: 'Latn' },
  { var: 'itLabel',     lang: 'it', tag: 'it',      region: 'it', script: 'Latn' }
].freeze

def build_query(platform_qids)
  optional_labels = LANGUAGES.map do |lang|
    raw = "#{lang[:var]}Raw"
    <<~SPARQL_FRAG
      OPTIONAL {
        ?item rdfs:label ?#{raw} .
        FILTER(LANG(?#{raw}) = "#{lang[:tag]}")
      }
    SPARQL_FRAG
  end.join

  sampled_labels = LANGUAGES.map do |lang|
    raw = "#{lang[:var]}Raw"
    "(SAMPLE(?#{raw}) AS ?#{lang[:var]})"
  end.join(' ')

  values_clause = "VALUES ?platformWD { #{platform_qids.map { |q| "wd:#{q}" }.join(' ')} }"

  # 1) Use a subquery to constrain the item set first.
  # 2) GROUP BY ?item with SAMPLE(...) so multiple OPTIONAL bindings
  #    (e.g. several release dates) collapse into a single row instead
  #    of cartesian-multiplying.
  <<~SPARQL
    SELECT ?item
           #{sampled_labels}
           (SAMPLE(?pubDateRaw) AS ?pubDate)
           (SAMPLE(?igdbIdRaw)  AS ?igdbId)
           (SAMPLE(?mobyIdRaw)  AS ?mobyId)
    WHERE {
      {
        SELECT DISTINCT ?item WHERE {
          #{values_clause}
          ?item wdt:P31 wd:Q7889 ;
                wdt:P400 ?platformWD .
        }
      }
      #{optional_labels}
      OPTIONAL { ?item wdt:P577   ?pubDateRaw . }
      OPTIONAL { ?item wdt:P5794  ?igdbIdRaw . }
      OPTIONAL { ?item wdt:P11688 ?mobyIdRaw . }
    }
    GROUP BY ?item
  SPARQL
end

def fetch(query, max_retries: 4)
  Tempfile.create(['sparql', '.rq']) do |f|
    f.write(query)
    f.flush

    url = "#{WIKIDATA_ENDPOINT}?format=json"

    attempt = 0
    loop do
      attempt += 1

      # -w '%{http_code}' appends status code to stdout so we can detect
      # silent failures (HTML error pages from the SPARQL endpoint).
      raw = `curl -s -X POST "#{url}" \
        --max-time 90 \
        -w '\\n%{http_code}' \
        -H "Content-Type: application/sparql-query" \
        -H "Accept: application/sparql-results+json" \
        -H "User-Agent: #{USER_AGENT}" \
        --data-binary @#{f.path}`

      curl_ok = $?.success?
      body, status = raw.rpartition("\n").then { |b, _, s| [b, s.strip] }

      if curl_ok && status == '200' && body.start_with?('{')
        return JSON.parse(body)
      end

      reason = curl_ok ? "HTTP #{status}" : "curl exit #{$?.exitstatus}"
      if attempt >= max_retries
        warn "SPARQL query failed after #{attempt} attempts (#{reason})"
        return nil
      end
      backoff = 2**attempt
      warn "  attempt #{attempt} failed (#{reason}); retrying in #{backoff}s..."
      sleep backoff
    end
  end
end

# Build a slug from arbitrary text. ASCII-only output.
# e.g. "Kirby's Dream Land" -> "kirbys-dream-land"
def slugify(text)
  return nil if text.nil? || text.empty?
  ascii = text.unicode_normalize(:nfkd).encode('ASCII', invalid: :replace, undef: :replace, replace: '')
  ascii.downcase
       .gsub(/[^a-z0-9\s-]+/, '')
       .strip
       .gsub(/\s+/, '-')
       .gsub(/-+/, '-')
       .gsub(/^-+|-+$/, '')
end

# Strip Wikipedia-style disambiguation suffixes from a Japanese label.
# e.g. "Centipede (ゲーム)"        -> "Centipede"
#      "F-1 Race (ゲームボーイ)"   -> "F-1 Race"
DISAMBIG_RE_JA = /\s*[(（](?:ゲーム|ビデオゲーム|コンピュータゲーム|ゲームボーイ|ファミリーコンピュータ|スーパーファミコン|任天堂|[0-9]{4}年のゲーム)[^)）]*[)）]\s*\z/.freeze
# Same for English Wikipedia disambiguators.
DISAMBIG_RE_EN = /\s*\((?:video game|game|[0-9]{4}\s*video\s*game)[^)]*\)\s*\z/i.freeze

def clean_label(text, lang)
  return text if text.nil?
  case lang
  when 'ja' then text.sub(DISAMBIG_RE_JA, '').strip
  when 'en' then text.sub(DISAMBIG_RE_EN, '').strip
  else           text.strip
  end
end

# Pull all available labels out of a SPARQL binding.
# Returns an array of {text, lang, script, region, tag}.
def collect_labels(binding)
  LANGUAGES.filter_map do |lang|
    raw = binding.dig(lang[:var], 'value')
    next nil if raw.nil? || raw.empty?

    text = clean_label(raw, lang[:lang])
    next nil if text.empty?

    {
      'text'   => text,
      'lang'   => lang[:lang],
      'script' => lang[:script] || ScriptDetector.detect(text),
      'region' => lang[:region]
    }
  end
end

# Build one schema-compliant entry from a single SPARQL binding.
def build_entry(binding, platform_id)
  wikidata_id = binding.dig('item', 'value')&.split('/')&.last
  pub_date    = binding.dig('pubDate', 'value')&.split('T')&.first
  igdb_id     = binding.dig('igdbId',  'value')
  moby_id     = binding.dig('mobyId',  'value')

  raw_labels = collect_labels(binding)
  return nil if raw_labels.empty?

  # Slug preference: English first, then any other Latin label, then the QID.
  en_text   = raw_labels.find { |t| t['lang'] == 'en' }&.dig('text')
  latn_text = raw_labels.find { |t| t['script'] == 'Latn' }&.dig('text')
  id = slugify(en_text) || slugify(latn_text) || wikidata_id&.downcase
  return nil if id.nil? || id.empty?

  titles = raw_labels.map do |t|
    t.merge(
      'form'     => 'official',
      'source'   => 'wikidata',
      'verified' => false
    )
  end

  entry = {
    'id'       => id,
    'platform' => platform_id,
    'category' => 'main_game',
    'titles'   => titles
  }

  entry['first_release_date'] = pub_date if pub_date

  external_ids = {}
  external_ids['wikidata']  = wikidata_id if wikidata_id
  external_ids['igdb']      = igdb_id.to_i if igdb_id && igdb_id.to_i.positive?
  external_ids['mobygames'] = moby_id.to_i if moby_id && moby_id.to_i.positive?
  entry['external_ids'] = external_ids unless external_ids.empty?

  entry
end

def write_entry(entry, platform_id, dry_run: false)
  dir = File.join(ROOT, 'data', 'games', platform_id)
  FileUtils.mkdir_p(dir) unless dry_run
  path = File.join(dir, "#{entry['id']}.json")

  if File.exist?(path) && !dry_run
    return :skipped
  end

  if dry_run
    :would_write
  else
    File.write(path, JSON.pretty_generate(entry) + "\n")
    :written
  end
end

def main
  options = { limit: nil, dry_run: false }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/fetch_wikidata.rb PLATFORM [options]\n" \
                  "  PLATFORM: #{PLATFORMS.keys.join(', ')}"
    opts.on('--limit N', Integer, 'limit the number of results (debug)') { |n| options[:limit] = n }
    opts.on('--dry-run', 'do not write files; only print stats')         { options[:dry_run] = true }
  end
  parser.parse!

  platform_id = ARGV.shift
  unless PLATFORMS.key?(platform_id)
    warn parser.help
    exit 1
  end

  meta = PLATFORMS[platform_id]
  puts "=== Wikidata fetch: #{meta[:name]} (#{meta[:qids].join(', ')}) ==="
  puts

  query = build_query(meta[:qids])
  data  = fetch(query)
  if data.nil?
    warn "ABORT: could not fetch #{platform_id} from Wikidata"
    exit 2
  end
  bindings = data.dig('results', 'bindings') || []
  puts "SPARQL bindings returned: #{bindings.size}"
  puts

  bindings = bindings.first(options[:limit]) if options[:limit]

  stats = Hash.new(0)
  seen_ids = {}
  script_stats = Hash.new(0)
  lang_stats   = Hash.new(0)

  bindings.each do |b|
    entry = build_entry(b, platform_id)
    if entry.nil?
      stats[:skipped_invalid] += 1
      next
    end

    if seen_ids[entry['id']]
      qid = entry.dig('external_ids', 'wikidata')
      entry['id'] = "#{entry['id']}-#{qid.downcase}" if qid
    end
    seen_ids[entry['id']] = true

    entry['titles'].each do |t|
      script_stats[t['script']] += 1
      lang_stats[t['lang']] += 1
    end

    result = write_entry(entry, platform_id, dry_run: options[:dry_run])
    stats[result] += 1
  end

  puts "=== Result ==="
  stats.each { |k, v| puts "  #{k}: #{v}" }
  puts
  puts "=== Title languages ==="
  lang_stats.sort_by { |_, v| -v }.each { |k, v| puts "  #{k}: #{v}" }
  puts
  puts "=== Title scripts (ISO 15924) ==="
  script_stats.sort_by { |_, v| -v }.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
