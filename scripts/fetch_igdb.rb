#!/usr/bin/env ruby
# frozen_string_literal: true

# Augment existing data/games/**/*.json entries with localized titles
# from IGDB (game_localizations + alternative_names).
#
# Authentication:
#   Set IGDB_CLIENT_ID and IGDB_CLIENT_SECRET in the environment.
#   Register an app at https://dev.twitch.tv/console/apps with
#   "Confidential" client type, localhost as the OAuth redirect URL,
#   and generate a new client secret.
#
# What it does:
#   1. Obtains a Twitch OAuth access token (Client Credentials Flow).
#   2. Fetches the regions lookup table (identifier -> id).
#   3. Walks data/games/**/*.json, collecting all igdb ids.
#   4. Batches 500 ids per POST /v4/games and expands
#      game_localizations.{name,region} and alternative_names.{name,comment}.
#   5. Merges new titles into each JSON file. Existing titles with the
#      same (text, lang, script) get promoted to verified: true when
#      they are confirmed by IGDB (= independent cross-source agreement).
#
# Rate limiting:
#   IGDB allows 4 requests/second. We throttle to 3 req/s to be safe.
#
# Usage:
#   ruby scripts/fetch_igdb.rb                     # real run
#   ruby scripts/fetch_igdb.rb --dry-run           # no writes
#   ruby scripts/fetch_igdb.rb --limit 50          # only first 50 games

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'

$stdout.sync = true

ROOT        = File.expand_path('..', __dir__)
SRC         = File.join(ROOT, 'data', 'games')
TOKEN_CACHE = File.join(ROOT, '.igdb_token.json')

IGDB_BASE  = 'https://api.igdb.com/v4'
TWITCH_URL = 'https://id.twitch.tv/oauth2/token'

BATCH_SIZE = 500   # maximum allowed by Apicalypse `limit`
RATE_SLEEP = 0.34  # ~3 req/sec; IGDB allows 4/sec

# Map IGDB region identifier -> default (lang, region_iso).
# Scripts are determined from the text itself via ScriptDetector, since
# a Japanese region can still yield a Latin transliteration.
#
# The IGDB /regions endpoint currently returns only three entries:
#   id=3 ja-JP "Japan", id=4 EU "Europe", id=2 ko-KR "Korea"
# The older release_dates.region enum (japan/north_america/...) is
# deprecated and does not apply to game_localizations.
REGION_DEFAULTS = {
  'ja-JP' => { lang: 'ja', region: 'jp' },
  'ko-KR' => { lang: 'ko', region: 'kr' },
  'EU'    => { lang: 'en', region: 'eu' }
}.freeze

# Map native-game-db platform id -> IGDB platform id(s).
# Several platforms have both a regional (JP) and a western (US/EU) IGDB
# entry; we include both so search results match either edition.
IGDB_PLATFORMS = {
  'fc'  => [18, 99],    # NES + Family Computer
  'sfc' => [19, 58],    # SNES + Super Famicom
  'gb'  => [33],
  'gbc' => [22],
  'gba' => [24],
  'md'  => [29],        # Sega Mega Drive / Genesis
  'pce' => [86],        # TurboGrafx-16 / PC Engine
  'n64' => [4],
  'nds' => [20],
  'ps1' => [7]          # PlayStation
}.freeze

# ---------------------------------------------------------------------------
# Auth

def load_cached_token
  return nil unless File.exist?(TOKEN_CACHE)
  data = JSON.parse(File.read(TOKEN_CACHE))
  return nil if data['expires_at'].to_i <= Time.now.to_i + 60
  data['access_token']
rescue StandardError
  nil
end

def obtain_token
  cached = load_cached_token
  return cached if cached

  client_id     = ENV['IGDB_CLIENT_ID']     || abort('IGDB_CLIENT_ID is not set')
  client_secret = ENV['IGDB_CLIENT_SECRET'] || abort('IGDB_CLIENT_SECRET is not set')

  uri = URI(TWITCH_URL)
  res = Net::HTTP.post_form(uri,
                            'client_id'     => client_id,
                            'client_secret' => client_secret,
                            'grant_type'    => 'client_credentials')
  abort "Twitch auth failed: #{res.code} #{res.body}" unless res.code == '200'

  data = JSON.parse(res.body)
  token = data.fetch('access_token')
  expires_at = Time.now.to_i + data.fetch('expires_in').to_i

  File.write(TOKEN_CACHE, JSON.pretty_generate('access_token' => token, 'expires_at' => expires_at))
  token
end

# ---------------------------------------------------------------------------
# IGDB request helper

def igdb_request(path, query, token)
  client_id = ENV.fetch('IGDB_CLIENT_ID')
  uri = URI("#{IGDB_BASE}#{path}")
  req = Net::HTTP::Post.new(uri)
  req['Client-ID']     = client_id
  req['Authorization'] = "Bearer #{token}"
  req['Accept']        = 'application/json'
  req.body             = query

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

  if res.code == '200'
    JSON.parse(res.body)
  elsif res.code == '429'
    warn '  rate limited, sleeping 2s...'
    sleep 2
    igdb_request(path, query, token)
  else
    abort "IGDB request failed: #{res.code} #{res.body}"
  end
end

def fetch_regions(token)
  map = {}
  offset = 0
  loop do
    query = "fields id, identifier, name; limit 500; offset #{offset};"
    rows = igdb_request('/regions', query, token)
    break if rows.empty?
    rows.each { |r| map[r['id']] = r }
    offset += rows.size
    sleep RATE_SLEEP
    break if rows.size < 500
  end
  map
end

# ---------------------------------------------------------------------------
# Local data scan

def collect_all_games
  Dir.glob(File.join(SRC, '*', '*.json')).sort.map do |path|
    { path: path, game: JSON.parse(File.read(path)) }
  end
end

# Find an English or Latin title from a game entry to use as a search query.
def primary_latin_title(game)
  title = game['titles'].find { |t| t['lang'] == 'en' && t['script'] == 'Latn' }
  title ||= game['titles'].find { |t| t['script'] == 'Latn' }
  title&.dig('text')
end

# Apicalypse escapes: quote quotes with a backslash.
def apic_escape(text)
  text.gsub('\\', '\\\\').gsub('"', '\\"')
end

# Search IGDB for a game by English title on a specific platform.
# Returns the IGDB id of the best match, or nil.
def resolve_igdb_id(title, platform_id, token)
  igdb_platforms = IGDB_PLATFORMS[platform_id]
  return nil if igdb_platforms.nil?

  query = <<~APIC
    search "#{apic_escape(title)}";
    fields id, name, platforms;
    where platforms = (#{igdb_platforms.join(',')});
    limit 10;
  APIC

  rows = igdb_request('/games', query, token)
  return nil if rows.nil? || rows.empty?

  tokens_in = token_set(title)
  return nil if tokens_in.empty?

  best = nil
  best_score = 0.0
  rows.each do |row|
    row_tokens = token_set(row['name'])
    next if row_tokens.empty?
    common = (tokens_in & row_tokens).size
    score = common.to_f / [tokens_in.size, row_tokens.size].min
    # Reward exact token-set equality to outrank substring matches.
    score += 0.2 if (tokens_in - row_tokens).empty? && (row_tokens - tokens_in).empty?
    if score > best_score
      best_score = score
      best = row['id']
    end
  end

  best_score >= 0.75 ? best : nil
end

# ---------------------------------------------------------------------------
# Merging logic

# Build a fresh title entry from an IGDB-origin text.
def build_title_from_igdb(text, region_identifier, form)
  defaults = REGION_DEFAULTS[region_identifier] || { lang: 'en', region: nil }
  {
    'text'     => text,
    'lang'     => defaults[:lang],
    'script'   => ScriptDetector.detect(text),
    'region'   => defaults[:region],
    'form'     => form,
    'source'   => 'igdb',
    'verified' => true
  }.compact
end

# Normalize two title strings for comparison.
def normalize(text)
  return '' if text.nil?
  text.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

# Reduce a title to ASCII-only word tokens for loose similarity.
def token_set(text)
  return [] if text.nil?
  ascii = text.unicode_normalize(:nfkd)
              .encode('ASCII', invalid: :replace, undef: :replace, replace: ' ')
              .downcase
              .gsub(/[^a-z0-9]+/, ' ')
  ascii.split.reject { |t| t.length < 2 }
end

# Guard against Wikidata mapping errors: if the IGDB game.name and the
# existing English/Latin title share almost no tokens, assume the IGDB id
# on the Wikidata entity is wrong and refuse to merge.
def safe_to_merge?(existing_titles, igdb_name)
  return false if igdb_name.nil? || igdb_name.strip.empty?

  igdb_tokens = token_set(igdb_name)
  return true if igdb_tokens.empty?

  latin_titles = existing_titles.select do |t|
    t['script'] == 'Latn' || (t['lang'] == 'en' || t['lang'] == 'ja')
  end
  return true if latin_titles.empty?

  best_overlap = latin_titles.map do |t|
    local = token_set(t['text'])
    next 0.0 if local.empty?
    common = (igdb_tokens & local).size
    # Use max() so a short IGDB name swallowed by a longer local title
    # (e.g. "Final Fantasy" vs "Final Fantasy VI") scores below 1.0.
    common.to_f / [igdb_tokens.size, local.size].max
  end.max

  # Require at least 60% token overlap against the longer title.
  best_overlap >= 0.6
end

# Given an existing titles array and an incoming IGDB title, decide whether
# - the existing title should be promoted to verified:true, or
# - the IGDB title should be appended as a new entry.
# Returns [updated_titles, :promoted | :added | :duplicate].
def merge_title(existing_titles, incoming)
  norm_in = normalize(incoming['text'])

  match = existing_titles.find do |t|
    t['lang'] == incoming['lang'] && normalize(t['text']) == norm_in
  end

  if match
    if match['source'] == 'igdb'
      return [existing_titles, :duplicate]
    end
    match['verified'] = true
    match['script']   = incoming['script'] if match['script'].nil? || match['script'] == 'Zyyy'
    return [existing_titles, :promoted]
  end

  [existing_titles + [incoming], :added]
end

def apply_igdb_data(game, igdb_row, regions_map)
  stats = Hash.new(0)
  titles = game['titles']

  unless safe_to_merge?(titles, igdb_row['name'])
    stats[:rejected_mismatch] += 1
    return stats
  end

  # Localized titles (structured, highest quality)
  (igdb_row['game_localizations'] || []).each do |loc|
    name = loc['name']
    next if name.nil? || name.strip.empty?

    region = regions_map[loc['region']]
    identifier = region&.dig('identifier')
    next if identifier.nil?

    incoming = build_title_from_igdb(name, identifier, 'official')
    titles, action = merge_title(titles, incoming)
    stats[action] += 1
  end

  # Alternative names (free text comment, used as a weaker signal)
  (igdb_row['alternative_names'] || []).each do |alt|
    name = alt['name']
    next if name.nil? || name.strip.empty?
    comment = (alt['comment'] || '').downcase

    # We only pick up romanizations here; anything else is too noisy to
    # trust without verification.
    next unless comment.include?('romanization') || comment.include?('romaji')

    incoming = build_title_from_igdb(name, 'japan', 'romaji_transliteration')
    titles, action = merge_title(titles, incoming)
    stats[action] += 1
  end

  game['titles'] = titles
  stats
end

# ---------------------------------------------------------------------------
# Main

def main
  options = { dry_run: false, limit: nil, search: false, platform: nil }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/fetch_igdb.rb [options]'
    opts.on('--dry-run', 'do not write files')            { options[:dry_run] = true }
    opts.on('--limit N', Integer, 'limit number of games') { |n| options[:limit] = n }
    opts.on('--search', 'resolve IGDB ids via search for entries without one') { options[:search] = true }
    opts.on('--platform ID', 'only process one platform') { |p| options[:platform] = p }
  end
  parser.parse!

  puts '=== IGDB augmentation ==='
  puts

  entries = collect_all_games
  entries.reject! { |e| e[:game]['platform'] != options[:platform] } if options[:platform]
  entries = entries.first(options[:limit]) if options[:limit]
  puts "Total games: #{entries.size}"

  token = obtain_token
  puts 'Auth OK.'

  puts 'Fetching regions...'
  regions_map = fetch_regions(token)
  puts "  got #{regions_map.size} regions"
  puts

  # ---------- Phase A: resolve IGDB ids for entries that lack one ----------
  if options[:search]
    puts '--- Phase A: search for missing IGDB ids ---'
    missing  = entries.reject { |e| e[:game].dig('external_ids', 'igdb') }
    puts "  #{missing.size} entries without an igdb id"

    resolved = 0
    skipped_no_title = 0
    search_fails = 0
    missing.each_with_index do |entry, i|
      title = primary_latin_title(entry[:game])
      if title.nil? || title.empty?
        skipped_no_title += 1
        next
      end

      platform_id = entry[:game]['platform']
      igdb_id = resolve_igdb_id(title, platform_id, token)
      sleep RATE_SLEEP

      if igdb_id
        entry[:game]['external_ids'] ||= {}
        entry[:game]['external_ids']['igdb'] = igdb_id
        entry[:resolved] = true
        resolved += 1
      else
        search_fails += 1
      end

      if ((i + 1) % 100).zero?
        puts "    searched #{i + 1}/#{missing.size}, resolved #{resolved}"
      end
    end
    puts "  resolved:         #{resolved}"
    puts "  search fails:     #{search_fails}"
    puts "  no latin title:   #{skipped_no_title}"
    puts
  end

  # ---------- Phase B: batch augment all entries with an IGDB id ----------
  puts '--- Phase B: batch fetch game_localizations + alternative_names ---'
  augment_targets = entries.select { |e| e[:game].dig('external_ids', 'igdb') }
  puts "  #{augment_targets.size} entries to augment"

  totals = Hash.new(0)
  not_found = 0
  removed_bad_id = 0

  augment_targets.each_slice(BATCH_SIZE).with_index do |batch, i|
    ids = batch.map { |e| e[:game].dig('external_ids', 'igdb') }.uniq
    query = <<~APIC
      fields name,
             game_localizations.name,
             game_localizations.region,
             alternative_names.name,
             alternative_names.comment;
      where id = (#{ids.join(',')});
      limit 500;
    APIC

    rows = igdb_request('/games', query, token)
    by_id = rows.to_h { |r| [r['id'], r] }
    puts "    batch #{i + 1}: requested #{ids.size}, got #{rows.size}"

    batch.each do |entry|
      igdb_id = entry[:game].dig('external_ids', 'igdb')
      row = by_id[igdb_id]
      if row.nil?
        not_found += 1
        next
      end

      stats = apply_igdb_data(entry[:game], row, regions_map)

      # If the IGDB row exists but has a mismatched name, it means the id
      # stored on this entry is wrong. Only remove ids that were inherited
      # from Wikidata (source: wikidata) — ids we resolved ourselves in
      # Phase A should never mismatch, but be defensive.
      if stats[:rejected_mismatch].positive? && !entry[:resolved]
        entry[:game]['external_ids'].delete('igdb')
        entry[:game].delete('external_ids') if entry[:game]['external_ids'].empty?
        removed_bad_id += 1
      end

      totals.merge!(stats) { |_, a, b| a + b }

      next if options[:dry_run]

      File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n")
    end

    sleep RATE_SLEEP
  end

  # Write back files where only the external_ids.igdb was added in Phase A
  # (Phase B did not mutate them because the augmentation was empty).
  unless options[:dry_run]
    entries.each do |entry|
      next unless entry[:resolved]
      File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n")
    end
  end

  puts
  puts '=== Result ==='
  puts "  added titles:          #{totals[:added]}"
  puts "  promoted to verified:  #{totals[:promoted]}"
  puts "  duplicate (skipped):   #{totals[:duplicate]}"
  puts "  rejected (name mism.): #{totals[:rejected_mismatch]}"
  puts "  removed bad IGDB ids:  #{removed_bad_id}"
  puts "  IGDB ids not found:    #{not_found}"
end

main if __FILE__ == $PROGRAM_NAME
