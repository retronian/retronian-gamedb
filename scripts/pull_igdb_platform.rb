#!/usr/bin/env ruby
# frozen_string_literal: true

# Paginate through every game IGDB has for a given native-game-db
# platform and create any that are still missing.
#
# This is the complement to fetch_igdb.rb --search:
#   - fetch_igdb.rb --search resolves an igdb id for existing entries.
#   - pull_igdb_platform.rb grabs every game IGDB has on the platform
#     and creates a new native-game-db entry when there is no match.
#
# New entries are built from whatever IGDB returns:
#   - titles[] gets `name` (en) plus every game_localization (ja/ko/...)
#   - external_ids.igdb is set
#   - first_release_date if present
#
# Requires IGDB_CLIENT_ID / IGDB_CLIENT_SECRET in the environment,
# same as fetch_igdb.rb. Honors the shared .igdb_token.json cache.
#
# Usage:
#   ruby scripts/pull_igdb_platform.rb --platform gb
#   ruby scripts/pull_igdb_platform.rb --platform gb --dry-run

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT        = File.expand_path('..', __dir__)
SRC         = File.join(ROOT, 'data', 'games')
TOKEN_CACHE = File.join(ROOT, '.igdb_token.json')

IGDB_BASE  = 'https://api.igdb.com/v4'
TWITCH_URL = 'https://id.twitch.tv/oauth2/token'
RATE_SLEEP = 0.34
PAGE_SIZE  = 500

IGDB_PLATFORMS = {
  'fc'  => [18, 99],
  'sfc' => [19, 58],
  'gb'  => [33],
  'gbc' => [22],
  'gba' => [24],
  'md'  => [29],
  'pce' => [86],
  'n64' => [4],
  'nds' => [20],
  'ps1' => [7]
}.freeze

REGION_DEFAULTS = {
  'ja-JP' => { lang: 'ja', region: 'jp' },
  'ko-KR' => { lang: 'ko', region: 'kr' },
  'EU'    => { lang: 'en', region: 'eu' }
}.freeze

# -------- Auth / HTTP --------

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
  File.write(TOKEN_CACHE, JSON.pretty_generate(
    'access_token' => data['access_token'],
    'expires_at'   => Time.now.to_i + data['expires_in'].to_i
  ))
  data['access_token']
end

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
    warn '  rate limited; sleeping 2s'
    sleep 2
    igdb_request(path, query, token)
  else
    abort "IGDB #{res.code}: #{res.body}"
  end
end

def fetch_regions(token)
  map = {}
  rows = igdb_request('/regions', 'fields id, identifier; limit 50;', token)
  rows.each { |r| map[r['id']] = r }
  map
end

# -------- DB index --------

def index_existing(platform_id)
  slug_index = DbIndex.build(SRC, platform_id)
  igdb_index = {}
  slug_index.values.uniq.each do |record|
    id = record[:game].dig('external_ids', 'igdb')
    igdb_index[id] = record if id
  end
  [slug_index, igdb_index]
end

def lookup_slug(index, text)
  DbIndex.lookup(index, text)
end

# -------- Entry builder --------

def title_from_localization(loc, regions_map)
  name = loc['name']
  return nil if name.nil? || name.strip.empty?
  region = regions_map[loc['region']]
  identifier = region&.dig('identifier')
  return nil if identifier.nil?
  defaults = REGION_DEFAULTS[identifier] || { lang: 'en' }
  {
    'text'     => name,
    'lang'     => defaults[:lang],
    'script'   => ScriptDetector.detect(name),
    'region'   => defaults[:region],
    'form'     => 'official',
    'source'   => 'igdb',
    'verified' => false
  }.compact
end

def build_entry(row, platform_id, regions_map)
  name = row['name']
  return nil if name.nil? || name.strip.empty?

  slug = Slug.slugify(name)
  return nil if slug.nil? || slug.empty?

  titles = [
    {
      'text'     => name,
      'lang'     => 'en',
      'script'   => ScriptDetector.detect(name),
      'region'   => 'us',
      'form'     => 'official',
      'source'   => 'igdb',
      'verified' => false
    }
  ]

  (row['game_localizations'] || []).each do |loc|
    t = title_from_localization(loc, regions_map)
    titles << t if t
  end

  (row['alternative_names'] || []).each do |alt|
    text = alt['name']
    next if text.nil? || text.strip.empty?
    comment = (alt['comment'] || '').downcase
    next unless comment.include?('romanization') || comment.include?('romaji')
    titles << {
      'text'     => text,
      'lang'     => 'ja',
      'script'   => 'Latn',
      'region'   => 'jp',
      'form'     => 'romaji_transliteration',
      'source'   => 'igdb',
      'verified' => false
    }
  end

  entry = {
    'id'       => slug,
    'platform' => platform_id,
    'category' => 'main_game',
    'titles'   => titles,
    'external_ids' => { 'igdb' => row['id'] }
  }

  if row['first_release_date']
    entry['first_release_date'] = Time.at(row['first_release_date']).utc.strftime('%Y-%m-%d')
  end

  entry
end

def write_new(entry)
  dir = File.join(SRC, entry['platform'])
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "#{entry['id']}.json")
  if File.exist?(path)
    existing = JSON.parse(File.read(path))
    # Never overwrite. Touch external_ids.igdb if missing.
    if existing.dig('external_ids', 'igdb').nil?
      existing['external_ids'] ||= {}
      existing['external_ids']['igdb'] = entry.dig('external_ids', 'igdb')
      File.write(path, JSON.pretty_generate(existing) + "\n")
      return :patched
    end
    return :exists
  end
  File.write(path, JSON.pretty_generate(entry) + "\n")
  :created
end

# -------- Main --------

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/pull_igdb_platform.rb --platform ID [--dry-run]'
    opts.on('--dry-run')             { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  platform_id = options[:platform]
  abort 'usage: --platform ID' if platform_id.nil?
  pf_ids = IGDB_PLATFORMS[platform_id]
  abort "unknown platform #{platform_id}" if pf_ids.nil?

  puts "=== IGDB full pull: #{platform_id} ==="
  token = obtain_token
  regions = fetch_regions(token)
  puts "  regions: #{regions.size}"

  slug_index, igdb_index = index_existing(platform_id)
  puts "  existing db entries: #{slug_index.values.uniq.size}"

  stats = Hash.new(0)
  offset = 0
  loop do
    query = <<~APIC
      fields id, name, first_release_date,
             game_localizations.name, game_localizations.region,
             alternative_names.name, alternative_names.comment;
      where platforms = (#{pf_ids.join(',')});
      sort id asc;
      limit #{PAGE_SIZE};
      offset #{offset};
    APIC
    rows = igdb_request('/games', query, token)
    puts "  page offset=#{offset}: got #{rows.size}"
    break if rows.empty?

    rows.each do |row|
      stats[:rows] += 1

      if igdb_index[row['id']]
        stats[:already_linked] += 1
        next
      end

      slug_hit = lookup_slug(slug_index, row['name'])
      if slug_hit
        existing = slug_hit[:game]
        if existing.dig('external_ids', 'igdb').nil?
          existing['external_ids'] ||= {}
          existing['external_ids']['igdb'] = row['id']
          File.write(slug_hit[:path], JSON.pretty_generate(existing) + "\n") unless options[:dry_run]
          stats[:linked] += 1
        else
          stats[:same_name_different_id] += 1
        end
        next
      end

      entry = build_entry(row, platform_id, regions)
      if entry.nil?
        stats[:skipped_invalid] += 1
        next
      end

      if options[:dry_run]
        stats[:would_create] += 1
      else
        action = write_new(entry)
        stats[action] += 1
        if action == :created
          Slug.aliases_for(entry['titles'].first['text']).each { |k| slug_index[k] ||= { path: File.join(SRC, platform_id, "#{entry['id']}.json"), game: entry } }
          igdb_index[row['id']] = slug_index[entry['id']]
        end
      end
    end

    break if rows.size < PAGE_SIZE
    offset += rows.size
    sleep RATE_SLEEP
  end

  puts
  puts '=== Result ==='
  stats.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
