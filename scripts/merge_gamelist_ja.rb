#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge Japanese titles from komagata/gamelist-ja's title_db.
#
# gamelist-ja/db/title_db/{platform}.json holds a per-platform database
# with three indices:
#   by_sha1     - SHA1 hash of the ROM file -> { ja, en, source }
#   by_filename - the canonical No-Intro filename -> { ja, en, source }
#   by_en_title - the normalized English title -> { ja, en, source }
#
# We use by_filename and by_en_title to match against retronian-gamedb
# entries by slug. The data quality varies by source (pigsaint > deepl)
# but every entry has a Japanese title we can record.
#
# Usage:
#   ruby scripts/merge_gamelist_ja.rb
#   ruby scripts/merge_gamelist_ja.rb --platform gb --dry-run

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT       = File.expand_path('..', __dir__)
SRC        = File.join(ROOT, 'data', 'games')
TITLE_DB   = '/home/komagata/Works/komagata/gamelist-ja/db/title_db'

# gamelist-ja platform stem -> retronian-gamedb platform id
PLATFORM_MAP = {
  'nes'       => 'fc',
  'snes'      => 'sfc',
  'gb'        => 'gb',
  'gbc'       => 'gbc',
  'gba'       => 'gba',
  'megadrive' => 'md',
  'pcengine'  => 'pce',
  'n64'       => 'n64',
  'psx'       => 'ps1'
  # neogeo, wonderswan, wonderswancolor are skipped (no matching db platform)
}.freeze

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

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

# Walk the title_db indices and produce a stream of {text => entry} pairs
# we can try to merge against retronian-gamedb using slug aliases.
def collect_candidates(title_db)
  candidates = {}

  (title_db['by_filename'] || {}).each do |filename, entry|
    text = Slug.strip_no_intro_suffixes(filename)
    next if text.empty?
    candidates[text] ||= entry
  end

  (title_db['by_en_title'] || {}).each do |en_title, entry|
    next if en_title.nil? || en_title.empty?
    candidates[en_title] ||= entry
  end

  candidates
end

def merge_entry(game, entry, source_label)
  stats = Hash.new(0)
  ja = entry['ja']
  return stats if ja.nil? || ja.strip.empty?

  # gamelist-ja's "deepl" source is machine-translated and unreliable;
  # never mark those as verified.
  src = entry['source'] || source_label
  trustworthy = %w[pigsaint manual offlinelist mame gamelist].include?(src)

  incoming = {
    'text'     => ja.strip,
    'lang'     => 'ja',
    'script'   => ScriptDetector.detect(ja),
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'gamelist_ja',
    'verified' => trustworthy
  }
  stats[add_title_if_new(game['titles'], incoming)] += 1
  stats
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_gamelist_ja.rb [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  puts '=== gamelist-ja merge ==='
  puts

  overall = Hash.new(0)
  PLATFORM_MAP.each do |stem, platform_id|
    next if options[:platform] && options[:platform] != platform_id

    path = File.join(TITLE_DB, "#{stem}.json")
    unless File.exist?(path)
      puts "  #{platform_id}: no title_db"
      next
    end

    title_db = JSON.parse(File.read(path))
    candidates = collect_candidates(title_db)
    db_index = index_db_games(platform_id)
    puts "  #{platform_id}: candidates=#{candidates.size}, db=#{db_index.values.uniq.size}"

    per = Hash.new(0)
    touched = {}
    candidates.each do |text, entry|
      record = lookup_record(db_index, text)
      if record.nil?
        per[:unmatched] += 1
        next
      end

      per[:matched] += 1
      stats = merge_entry(record[:game], entry, 'gamelist_ja')
      stats.each { |k, v| per[k] += v }
      touched[record[:path]] = record[:game]
    end

    unless options[:dry_run]
      touched.each do |path, game|
        File.write(path, JSON.pretty_generate(game) + "\n")
      end
    end

    summary = per.map { |k, v| "#{k}=#{v}" }.join(', ')
    puts "      #{summary}"
    per.each { |k, v| overall[k] += v }
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
