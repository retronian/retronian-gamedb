#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge hand-curated Japanese metadata from retronian/romu into this DB.
#
# romu's internal/gamedb/data/{platform}.json is keyed by No-Intro name
# (e.g. "Kirby's Dream Land (Japan)") and each value holds:
#   { title_ja, desc_ja, developer, publisher, genre, players, release_date }
#
# Those entries are human-edited and the desc_ja fields are a rich
# source of Japanese prose that Wikidata/IGDB simply do not have. We
# merge them into the matching retronian-gamedb entry by slug.
#
# Usage:
#   ruby scripts/merge_romu.rb                        # all platforms
#   ruby scripts/merge_romu.rb --platform gb
#   ruby scripts/merge_romu.rb --dry-run

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT        = File.expand_path('..', __dir__)
SRC         = File.join(ROOT, 'data', 'games')
ROMU_GAMEDB = '/home/komagata/Works/retronian/romu/internal/gamedb/data'

# romu platform id -> retronian-gamedb platform id
PLATFORM_MAP = {
  'fc'  => 'fc',
  'sfc' => 'sfc',
  'gb'  => 'gb',
  'gbc' => 'gbc',
  'gba' => 'gba',
  'md'  => 'md',
  'pce' => 'pce',
  'n64' => 'n64',
  'nds' => 'nds'
  # romu has ngp/ws/wsc as well but retronian-gamedb only covers platforms
  # with No-Intro DAT coverage + PlayStation.
}.freeze

def strip_no_intro_suffixes(name)
  Slug.strip_no_intro_suffixes(name)
end

def slugify(text)
  Slug.slugify(text)
end

# Convert romu's compact release_date ("19940805T000000") to ISO 8601.
def iso_date(compact)
  return nil if compact.nil? || compact.empty?
  m = compact.match(/\A(\d{4})(\d{2})(\d{2})/)
  return nil unless m
  y, mo, d = m[1], m[2], m[3]
  return y               if mo == '00' && d == '00'
  return "#{y}-#{mo}"    if d == '00'
  "#{y}-#{mo}-#{d}"
end

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

def load_romu(platform_id)
  path = File.join(ROMU_GAMEDB, "#{platform_id}.json")
  return {} unless File.exist?(path)
  JSON.parse(File.read(path))
end

# Build an index { slug => entry } for retronian-gamedb on a platform.
# A single entry may be reachable via multiple slugs (its own id + the
# slug of every Latin title it holds), so we can match romu keys that
# use spellings like "Double Dragon II - The Revenge" vs the db id.
def index_db_games(platform_id)
  DbIndex.build(SRC, platform_id)
end

def lookup_record(index, text)
  DbIndex.lookup(index, text)
end

def add_title_if_new(titles, incoming)
  norm = normalize(incoming['text'])
  match = titles.find { |t| t['lang'] == incoming['lang'] && normalize(t['text']) == norm }
  if match
    match['verified'] = true if incoming['verified'] && !match['verified']
    :duplicate
  else
    titles << incoming
    :added
  end
end

def add_description_if_new(descs, incoming)
  norm = normalize(incoming['text'])
  return :duplicate if descs.any? { |d| d['lang'] == incoming['lang'] && normalize(d['text']) == norm }
  descs << incoming
  :added
end

def merge_entry(game, no_intro_name, romu_entry)
  stats = Hash.new(0)

  clean_en = strip_no_intro_suffixes(no_intro_name)
  title_ja = romu_entry['title_ja']
  desc_ja  = romu_entry['desc_ja']

  # 1) English No-Intro title -> titles[]
  en_incoming = {
    'text'     => clean_en,
    'lang'     => 'en',
    'script'   => 'Latn',
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'romu',
    'verified' => false
  }
  stats[add_title_if_new(game['titles'], en_incoming)] += 1

  # 2) Japanese title -> titles[]
  if title_ja && !title_ja.strip.empty?
    ja_incoming = {
      'text'     => title_ja,
      'lang'     => 'ja',
      'script'   => ScriptDetector.detect(title_ja),
      'region'   => 'jp',
      'form'     => 'official',
      'source'   => 'romu',
      'verified' => true
    }
    r = add_title_if_new(game['titles'], ja_incoming)
    stats["ja_#{r}".to_sym] += 1
  end

  # 3) Japanese description -> descriptions[]
  if desc_ja && !desc_ja.strip.empty?
    game['descriptions'] ||= []
    desc_incoming = { 'text' => desc_ja, 'lang' => 'ja', 'source' => 'romu' }
    r = add_description_if_new(game['descriptions'], desc_incoming)
    stats["desc_#{r}".to_sym] += 1
  end

  # 4) first_release_date from romu release_date, only if unset
  if game['first_release_date'].nil?
    iso = iso_date(romu_entry['release_date'])
    if iso
      game['first_release_date'] = iso
      stats[:date_added] += 1
    end
  end

  stats
end

def main
  options = { dry_run: false, platform: nil }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_romu.rb [options]'
    opts.on('--dry-run', 'do not write files') { options[:dry_run] = true }
    opts.on('--platform ID', 'only process one platform') { |p| options[:platform] = p }
  end
  parser.parse!

  puts '=== romu gamedb merge ==='
  puts

  overall = Hash.new(0)
  platforms = options[:platform] ? [options[:platform]] : PLATFORM_MAP.keys

  platforms.each do |platform_id|
    romu = load_romu(platform_id)
    if romu.empty?
      puts "  #{platform_id}: no romu data"
      next
    end

    db_index = index_db_games(platform_id)
    puts "  #{platform_id}: romu=#{romu.size}, db=#{db_index.values.uniq.size}"

    per = Hash.new(0)
    touched_paths = {}

    romu.each do |no_intro_name, entry|
      clean = strip_no_intro_suffixes(no_intro_name)
      record = lookup_record(db_index, clean)
      if record.nil?
        per[:unmatched] += 1
        next
      end

      per[:matched] += 1
      stats = merge_entry(record[:game], no_intro_name, entry)
      stats.each { |k, v| per[k] += v }
      touched_paths[record[:path]] = record[:game]
    end

    unless options[:dry_run]
      touched_paths.each do |path, game|
        File.write(path, JSON.pretty_generate(game) + "\n")
      end
    end

    per.each { |k, v| overall[k] += v }
    summary = per.map { |k, v| "#{k}=#{v}" }.join(', ')
    puts "      #{summary}"
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
