#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge SHA1-verified Japanese titles from komagata/skyscraper-ja.
#
# skyscraper-ja/csv/{platform}_matches.csv holds the result of matching
# No-Intro ROM filenames against the game-soft Japanese metadata. Rows
# whose status is "matched" have been confirmed via SHA1 hashing, so
# they are the most trustworthy mapping from an English No-Intro name
# to a Japanese title that we have access to.
#
# Usage:
#   ruby scripts/merge_skyscraper_ja.rb
#   ruby scripts/merge_skyscraper_ja.rb --platform gb --dry-run

require 'json'
require 'csv'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
CSV_DIR = '/home/komagata/Works/komagata/skyscraper-ja/csv'

# CSV file stem -> retronian-gamedb platform id
PLATFORM_MAP = {
  'nes'       => 'fc',
  'snes'      => 'sfc',
  'gb'        => 'gb',
  'gbc'       => 'gbc',
  'gba'       => 'gba',
  'megadrive' => 'md',
  'pcengine'  => 'pce',
  'n64'       => 'n64'
}.freeze

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

# Turn a ROM filename into the canonical title text for matching.
# "Hoshi no Kirby Super Deluxe (Japan).zip" -> "Hoshi no Kirby Super Deluxe"
def filename_to_text(filename)
  filename.sub(/\.(zip|7z|rar|smc|sfc|nes|gb|gbc|gba|md|gen|bin|iso|cue|pce)\z/i, '')
          .gsub(/\s*\([^)]*\)/, '')
          .strip
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

def merge_row(game, row)
  stats = Hash.new(0)
  ja_title = row['ja_title']
  return stats if ja_title.nil? || ja_title.strip.empty?

  incoming = {
    'text'     => ja_title.strip,
    'lang'     => 'ja',
    'script'   => ScriptDetector.detect(ja_title),
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'skyscraper_ja',
    'verified' => true
  }
  stats[add_title_if_new(game['titles'], incoming)] += 1

  if row['ss_releasedate'] && !row['ss_releasedate'].strip.empty? && game['first_release_date'].nil?
    game['first_release_date'] = row['ss_releasedate'].strip
    stats[:date_added] += 1
  end

  stats
end

def process_csv(csv_path, platform_id, dry_run:)
  db_index = index_db_games(platform_id)
  per = Hash.new(0)
  touched = {}

  CSV.foreach(csv_path, headers: true) do |row|
    per[:rows] += 1
    next unless row['status'] == 'matched'
    per[:sha1_matched] += 1

    text = filename_to_text(row['filename'] || '')
    record = lookup_record(db_index, text)
    if record.nil?
      per[:unmatched_slug] += 1
      next
    end

    per[:merged] += 1
    stats = merge_row(record[:game], row)
    stats.each { |k, v| per[k] += v }
    touched[record[:path]] = record[:game]
  end

  unless dry_run
    touched.each do |path, game|
      File.write(path, JSON.pretty_generate(game) + "\n")
    end
  end

  per
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_skyscraper_ja.rb [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  puts '=== skyscraper-ja merge ==='
  puts

  overall = Hash.new(0)
  PLATFORM_MAP.each do |csv_stem, platform_id|
    next if options[:platform] && options[:platform] != platform_id

    csv_path = File.join(CSV_DIR, "#{csv_stem}_matches.csv")
    unless File.exist?(csv_path)
      puts "  #{platform_id}: no csv"
      next
    end

    per = process_csv(csv_path, platform_id, dry_run: options[:dry_run])
    summary = per.map { |k, v| "#{k}=#{v}" }.join(', ')
    puts "  #{platform_id}: #{summary}"
    per.each { |k, v| overall[k] += v }
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
