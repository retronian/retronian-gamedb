#!/usr/bin/env ruby
# frozen_string_literal: true

# Pull No-Intro DAT files into retronian-gamedb's roms[] layer.
#
# Each DAT file contains hundreds to thousands of <game> entries with
# ROM hashes (CRC32/MD5/SHA1/SHA256), file sizes, cartridge serials and
# the canonical No-Intro name. We parse those, match each game back to
# a retronian-gamedb entry by slug, and append a roms[] entry with all
# the hash data we have. If the match already carries a rom with the
# same name we skip it.
#
# Usage:
#   ruby scripts/merge_no_intro.rb                  # all platforms
#   ruby scripts/merge_no_intro.rb --platform gb
#   ruby scripts/merge_no_intro.rb --dry-run

require 'json'
require 'rexml/document'
require 'fileutils'
require 'optparse'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT      = File.expand_path('..', __dir__)
SRC       = File.join(ROOT, 'data', 'games')
DAT_DIR   = '/home/komagata/Works/komagata/no-intro-dat'

# Pick the newest-looking DAT file for each platform. The directory
# contains multiple naming conventions (short like "gb.dat" and long
# like "Nintendo - Game Boy (20260113-102506).dat"); we prefer the
# short names first and fall back to pattern matches.
PLATFORM_DATS = {
  'fc'  => %w[nes.dat Nintendo\ -\ Nintendo\ Entertainment\ System.dat],
  'sfc' => %w[snes.dat Nintendo\ -\ Super\ Nintendo\ Entertainment\ System.dat],
  'gb'  => %w[gb.dat],
  'gbc' => %w[gbc.dat],
  'gba' => %w[gba.dat],
  'md'  => %w[megadrive.dat],
  'pce' => %w[pcengine.dat],
  'n64' => %w[n64.dat],
  'nds' => [],  # filled below by glob
  'ps1' => %w[psx.dat]
}.freeze

def find_dat(platform_id)
  PLATFORM_DATS[platform_id].each do |name|
    path = File.join(DAT_DIR, name)
    return path if File.exist?(path)
  end
  # Fallback glob for long-named files (e.g. NDS decrypted).
  case platform_id
  when 'nds'
    Dir.glob(File.join(DAT_DIR, 'Nintendo - Nintendo DS*.dat')).first
  else
    nil
  end
end

def region_from_name(name)
  inside = name.scan(/\(([^)]+)\)/).flatten.join(', ').downcase
  return 'jp' if inside.include?('japan')
  return 'us' if inside.include?('usa')
  return 'eu' if inside.include?('europe')
  return 'kr' if inside.include?('korea')
  return 'cn' if inside.include?('china')
  return 'tw' if inside.include?('taiwan')
  return 'au' if inside.include?('australia')
  return 'br' if inside.include?('brazil')
  nil
end

def index_db_games(platform_id)
  DbIndex.build(SRC, platform_id)
end

def lookup_record(index, text)
  DbIndex.lookup(index, text)
end

def rom_attrs(rom_el)
  attrs = {}
  %w[size crc md5 sha1 sha256 serial status].each do |k|
    v = rom_el.attributes[k]
    attrs[k] = v unless v.nil? || v.empty?
  end
  attrs
end

def build_rom_entry(game_name, rom_el)
  attrs = rom_attrs(rom_el)
  entry = {
    'name'   => game_name,
    'source' => 'no_intro'
  }
  region = region_from_name(game_name)
  entry['region'] = region if region
  entry['serial'] = attrs['serial']     if attrs['serial']
  entry['size']   = attrs['size'].to_i  if attrs['size']
  entry['crc32']  = attrs['crc'].downcase  if attrs['crc']
  entry['md5']    = attrs['md5'].downcase  if attrs['md5']
  entry['sha1']   = attrs['sha1'].downcase if attrs['sha1']
  entry['sha256'] = attrs['sha256'].downcase if attrs['sha256']
  entry
end

def add_rom_if_new(game, incoming)
  game['roms'] ||= []
  existing = game['roms'].find { |r| r['name'] == incoming['name'] }
  if existing
    merged = false
    %w[size crc32 md5 sha1 sha256 serial region].each do |k|
      if existing[k].nil? && incoming[k]
        existing[k] = incoming[k]
        merged = true
      end
    end
    merged ? :updated : :duplicate
  else
    game['roms'] << incoming
    :added
  end
end

def process_platform(platform_id, dry_run:)
  dat_path = find_dat(platform_id)
  return { dat: nil } unless dat_path

  xml = File.read(dat_path)
  doc = REXML::Document.new(xml)
  db_index = index_db_games(platform_id)
  per = Hash.new(0)
  touched = {}

  doc.root.elements.each('game') do |game_el|
    per[:rows] += 1
    name = game_el.attributes['name']
    next if name.nil? || name.empty?

    clean = Slug.strip_no_intro_suffixes(name)
    record = lookup_record(db_index, clean)
    if record.nil?
      per[:unmatched] += 1
      next
    end

    per[:matched] += 1
    game_el.elements.each('rom') do |rom_el|
      rom_entry = build_rom_entry(name, rom_el)
      action = add_rom_if_new(record[:game], rom_entry)
      per[action] += 1
    end
    touched[record[:path]] = record[:game]
  end

  unless dry_run
    touched.each do |path, game|
      File.write(path, JSON.pretty_generate(game) + "\n")
    end
  end

  per[:dat] = File.basename(dat_path)
  per
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_no_intro.rb [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  puts '=== no-intro DAT merge ==='
  puts

  overall = Hash.new(0)
  platforms = options[:platform] ? [options[:platform]] : PLATFORM_DATS.keys

  platforms.each do |platform_id|
    stats = process_platform(platform_id, dry_run: options[:dry_run])
    if stats[:dat].nil?
      puts "  #{platform_id}: no DAT"
      next
    end
    puts "  #{platform_id.ljust(4)} dat=#{stats[:dat]}"
    stats.each { |k, v| next if k == :dat; overall[k] += v; }
    %i[rows matched unmatched added duplicate updated].each do |k|
      puts "      #{k}=#{stats[k]}" if stats[k].to_i.positive?
    end
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
