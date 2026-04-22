#!/usr/bin/env ruby
# frozen_string_literal: true

# Populate descriptions[] from two upstream sources:
#
#   --source igdb      -> POST /v4/games  with fields summary, storyline
#                         (English only but rich, 100-500 chars)
#   --source wikidata  -> SPARQL with schema:description in en/ja/ko/zh/
#                         fr/es/de/it. Shorter (usually one sentence)
#                         but multilingual so you can drop it straight
#                         into per-language entries.
#
# Games are processed by platform. Both sources are idempotent: if a
# language/source pair already exists on the entry it is left alone,
# otherwise a new descriptions[] element is pushed.
#
# Usage:
#   IGDB_CLIENT_ID=... IGDB_CLIENT_SECRET=... \
#     ruby scripts/fetch_descriptions.rb --source igdb --platform gb
#   ruby scripts/fetch_descriptions.rb --source wikidata --platform gb
#   ruby scripts/fetch_descriptions.rb --source wikidata   # all platforms
#   ruby scripts/fetch_descriptions.rb --source igdb --dry-run --limit 10

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'tempfile'
require 'open3'

$stdout.sync = true

ROOT        = File.expand_path('..', __dir__)
SRC         = File.join(ROOT, 'data', 'games')
TOKEN_CACHE = File.join(ROOT, '.igdb_token.json')

IGDB_BASE  = 'https://api.igdb.com/v4'
TWITCH_URL = 'https://id.twitch.tv/oauth2/token'
USER_AGENT = 'native-game-db/0.1 (https://gamedb.retronian.com)'
RATE_SLEEP = 0.34
BATCH      = 500
WD_BATCH   = 100

WIKIDATA_LANGS = %w[en ja ko zh fr es de it pt ru].freeze

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1].freeze

# ---------- IGDB auth ----------

def obtain_token
  if File.exist?(TOKEN_CACHE)
    data = JSON.parse(File.read(TOKEN_CACHE))
    return data['access_token'] if data['expires_at'].to_i > Time.now.to_i + 60
  end

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

  return JSON.parse(res.body) if res.code == '200'
  if res.code == '429'
    warn '  rate limited, sleeping 2s'
    sleep 2
    return igdb_request(path, query, token)
  end
  abort "IGDB #{res.code}: #{res.body}"
end

# ---------- Wikidata SPARQL ----------

def wikidata_sparql(query, max_retries: 4)
  Tempfile.create(['sparql', '.rq']) do |f|
    f.write(query)
    f.flush
    attempt = 0
    loop do
      attempt += 1
      out, _ = Open3.capture2('curl', '-s', '-X', 'POST',
                              '--max-time', '60',
                              'https://query.wikidata.org/sparql?format=json',
                              '-H', 'Content-Type: application/sparql-query',
                              '-H', 'Accept: application/sparql-results+json',
                              '-H', "User-Agent: #{USER_AGENT}",
                              '--data-binary', "@#{f.path}")
      if out.start_with?('{')
        begin
          return JSON.parse(out)
        rescue JSON::ParserError
          # fall through to retry
        end
      end
      if attempt >= max_retries
        warn "    sparql failed after #{attempt} attempts"
        return { 'results' => { 'bindings' => [] } }
      end
      backoff = 2**attempt
      warn "    sparql attempt #{attempt} failed, retry in #{backoff}s"
      sleep backoff
    end
  end
end

# ---------- Data helpers ----------

def each_platform_game(platform_id)
  Dir.glob(File.join(SRC, platform_id, '*.json')).sort.each do |path|
    yield path, JSON.parse(File.read(path))
  end
end

def add_description_if_new(descriptions, incoming)
  existing = descriptions.find do |d|
    d['lang'] == incoming['lang'] && d['source'] == incoming['source']
  end
  return :duplicate if existing

  descriptions << incoming
  :added
end

# ---------- IGDB path ----------

def run_igdb(platforms, dry_run:, limit:)
  token = obtain_token
  platforms.each do |pf|
    entries = []
    each_platform_game(pf) do |path, game|
      igdb_id = game.dig('external_ids', 'igdb')
      next unless igdb_id.is_a?(Integer)
      entries << { path: path, game: game, igdb_id: igdb_id }
    end
    entries = entries.first(limit) if limit
    puts "  #{pf}: #{entries.size} entries with an igdb id"
    next if entries.empty?

    totals = Hash.new(0)
    entries.each_slice(BATCH).with_index do |batch, i|
      ids = batch.map { |e| e[:igdb_id] }.uniq
      query = <<~APIC
        fields id, summary, storyline;
        where id = (#{ids.join(',')});
        limit 500;
      APIC
      rows = igdb_request('/games', query, token)
      by_id = rows.to_h { |r| [r['id'], r] }
      puts "    batch #{i + 1}: asked #{ids.size}, got #{rows.size}"

      batch.each do |entry|
        row = by_id[entry[:igdb_id]]
        next unless row
        descs = entry[:game]['descriptions'] ||= []
        dirty = false

        if row['summary'] && !row['summary'].strip.empty?
          res = add_description_if_new(descs,
                                       'text'   => row['summary'].strip,
                                       'lang'   => 'en',
                                       'source' => 'igdb')
          totals[res] += 1
          dirty = true if res == :added
        end

        if row['storyline'] && !row['storyline'].strip.empty? && row['storyline'] != row['summary']
          res = add_description_if_new(descs,
                                       'text'   => row['storyline'].strip,
                                       'lang'   => 'en',
                                       'source' => 'igdb_storyline')
          totals[res] += 1
          dirty = true if res == :added
        end

        File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n") if dirty && !dry_run
      end

      sleep RATE_SLEEP
    end

    puts "    totals: #{totals}"
  end
end

# ---------- Wikidata path ----------

def run_wikidata(platforms, dry_run:, limit:)
  platforms.each do |pf|
    entries = []
    each_platform_game(pf) do |path, game|
      qid = game.dig('external_ids', 'wikidata')
      next unless qid
      entries << { path: path, game: game, qid: qid }
    end
    entries = entries.first(limit) if limit
    puts "  #{pf}: #{entries.size} entries with a wikidata qid"
    next if entries.empty?

    totals = Hash.new(0)
    entries.each_slice(WD_BATCH).with_index do |batch, i|
      qids = batch.map { |e| e[:qid] }.uniq
      lang_filter = WIKIDATA_LANGS.map { |l| %("#{l}") }.join(',')
      query = <<~SPARQL
        SELECT ?item ?desc WHERE {
          VALUES ?item { #{qids.map { |q| "wd:#{q}" }.join(' ')} }
          ?item schema:description ?desc .
          FILTER(LANG(?desc) IN (#{lang_filter}))
        }
      SPARQL
      data = wikidata_sparql(query)
      bindings = data.dig('results', 'bindings') || []
      puts "    batch #{i + 1}: asked #{qids.size}, got #{bindings.size} descriptions"

      # Collect per-QID language descriptions
      by_qid = {}
      bindings.each do |b|
        qid = b.dig('item', 'value')&.split('/')&.last
        desc = b.dig('desc', 'value')
        lang = b.dig('desc', 'xml:lang')
        next unless qid && desc && lang
        by_qid[qid] ||= []
        by_qid[qid] << { lang: lang, text: desc }
      end

      batch.each do |entry|
        rows = by_qid[entry[:qid]]
        next unless rows
        descs = entry[:game]['descriptions'] ||= []
        dirty = false

        rows.each do |r|
          res = add_description_if_new(descs,
                                       'text'   => r[:text],
                                       'lang'   => r[:lang],
                                       'source' => 'wikidata')
          totals[res] += 1
          dirty = true if res == :added
        end

        File.write(entry[:path], JSON.pretty_generate(entry[:game]) + "\n") if dirty && !dry_run
      end

      sleep 0.5
    end

    puts "    totals: #{totals}"
  end
end

# ---------- Main ----------

def main
  options = { source: nil, dry_run: false, platform: nil, limit: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/fetch_descriptions.rb --source igdb|wikidata [options]'
    opts.on('--source SRC', 'igdb | wikidata') { |s| options[:source] = s }
    opts.on('--platform ID') { |p| options[:platform] = p }
    opts.on('--dry-run')    { options[:dry_run] = true }
    opts.on('--limit N', Integer) { |n| options[:limit] = n }
  end.parse!

  src = options[:source] or abort 'usage: --source igdb|wikidata'
  platforms = options[:platform] ? [options[:platform]] : PLATFORMS

  puts "=== fetch_descriptions (#{src}) ==="
  case src
  when 'igdb'     then run_igdb(platforms, dry_run: options[:dry_run], limit: options[:limit])
  when 'wikidata' then run_wikidata(platforms, dry_run: options[:dry_run], limit: options[:limit])
  else abort "unknown source: #{src}"
  end
end

main if __FILE__ == $PROGRAM_NAME
