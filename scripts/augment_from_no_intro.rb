#!/usr/bin/env ruby
# frozen_string_literal: true

# Promote unmatched No-Intro DAT entries into new retronian-gamedb games.
#
# merge_no_intro.rb only appends roms[] to *existing* games. This script
# is the complement: it walks the same DAT file, groups entries whose
# No-Intro name collapses to the same base title (with " (Japan)",
# " (Rev A)", etc stripped), and for any base title that has no match
# in retronian-gamedb it creates a brand new game JSON file.
#
# The new entry starts with:
#   - id   = slug of the base title
#   - platform = the given retronian-gamedb platform id
#   - titles[] = one "source: no_intro" entry per distinct region we saw
#   - roms[]   = every <rom> node from the DAT for that base title
#
# Later, merge_romu / merge_skyscraper_ja / merge_gamelist_ja /
# fetch_igdb --search / fetch_covers can all be re-run on top to fill
# in Japanese titles, descriptions, IGDB/Wikidata ids and cover art.
#
# Usage:
#   ruby scripts/augment_from_no_intro.rb --platform gb
#   ruby scripts/augment_from_no_intro.rb --platform gb --dry-run

require 'json'
require 'rexml/document'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'
require_relative 'lib/slug'
require_relative 'lib/db_index'

$stdout.sync = true

ROOT    = File.expand_path('..', __dir__)
SRC     = File.join(ROOT, 'data', 'games')
DAT_DIR = '/home/komagata/Works/komagata/no-intro-dat'

PLATFORM_DATS = {
  'fc'  => %w[nes.dat],
  'sfc' => %w[snes.dat],
  'gb'  => %w[gb.dat],
  'gbc' => %w[gbc.dat],
  'gba' => %w[gba.dat],
  'md'  => %w[megadrive.dat],
  'pce' => %w[pcengine.dat],
  'n64' => %w[n64.dat],
  'nds' => [],
  'ps1' => %w[psx.dat]
}.freeze

def find_dat(platform_id)
  PLATFORM_DATS[platform_id].each do |name|
    path = File.join(DAT_DIR, name)
    return path if File.exist?(path)
  end
  case platform_id
  when 'nds' then Dir.glob(File.join(DAT_DIR, 'Nintendo - Nintendo DS*.dat')).first
  else nil
  end
end

def index_existing(platform_id)
  DbIndex.build(SRC, platform_id)
end

def lookup(index, text)
  DbIndex.lookup(index, text)
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

# Unofficial dumps flood the DAT with noise. Skip them for new-game
# creation — they rarely warrant a dedicated entry.
def junk_entry?(name)
  noise = %w[(Unl) (Beta) (Proto) (Demo) (Sample) (Test) (Debug) (Prototype) (Hack) (Aftermarket) (Pirate) (Homebrew)]
  noise.any? { |s| name.include?(s) }
end

def build_rom(game_name, rom_el)
  entry = { 'name' => game_name, 'source' => 'no_intro' }
  region = region_from_name(game_name)
  entry['region'] = region if region
  %w[serial size crc md5 sha1 sha256].each do |k|
    v = rom_el.attributes[k]
    next if v.nil? || v.empty?
    case k
    when 'size' then entry['size']  = v.to_i
    when 'crc'  then entry['crc32'] = v.downcase
    else             entry[k] = v.downcase if %w[md5 sha1 sha256].include?(k)
    end
    entry['serial'] = v if k == 'serial'
  end
  entry
end

def process(platform_id, dry_run:)
  dat = find_dat(platform_id)
  abort "no DAT for #{platform_id}" unless dat

  doc = REXML::Document.new(File.read(dat))
  existing = index_existing(platform_id)

  # Group DAT entries by base title.
  groups = {}
  doc.root.elements.each('game') do |g|
    name = g.attributes['name']
    next if name.nil? || name.empty?
    next if junk_entry?(name)

    base = Slug.strip_no_intro_suffixes(name)
    next if base.empty?

    groups[base] ||= { name: base, roms: [] }
    groups[base][:roms] << { name: name, el: g }
  end

  puts "  DAT: #{File.basename(dat)}"
  puts "  unique base titles: #{groups.size}"

  created = 0
  skipped_existing = 0
  skipped_no_slug  = 0

  groups.each do |base, data|
    next if lookup(existing, base)
    skipped_existing += 1 and next if false

    slug = Slug.slugify(base)
    if slug.nil? || slug.empty?
      skipped_no_slug += 1
      next
    end

    next if existing[slug]

    # Pick a representative region for the canonical title.
    roms = data[:roms]
    primary_region = nil
    %w[us jp eu].each do |want|
      if roms.any? { |r| region_from_name(r[:name]) == want }
        primary_region = want
        break
      end
    end

    titles = [
      {
        'text'     => base,
        'lang'     => 'en',
        'script'   => 'Latn',
        'form'     => 'official',
        'source'   => 'no_intro',
        'verified' => false
      }
    ]
    titles.last['region'] = primary_region if primary_region

    entry = {
      'id'       => slug,
      'platform' => platform_id,
      'category' => 'main_game',
      'titles'   => titles,
      'roms'     => roms.map { |r| build_rom(r[:name], r[:el].elements['rom']) }
    }

    path = File.join(SRC, platform_id, "#{slug}.json")
    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(entry) + "\n")
      # Register in index so later groups collapse into this entry.
      existing[slug] = { path: path, game: entry }
      Slug.aliases_for(base).each { |k| existing[k] ||= existing[slug] }
    end
    created += 1
  end

  (existing.keys - groups.keys).size
  puts "  skipped_no_slug: #{skipped_no_slug}"
  puts "  created:         #{created}"
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  abort 'usage: --platform ID' if options[:platform].nil?

  puts "=== augment from no-intro: #{options[:platform]} ==="
  process(options[:platform], dry_run: options[:dry_run])
end

main if __FILE__ == $PROGRAM_NAME
