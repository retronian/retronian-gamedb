#!/usr/bin/env ruby
# frozen_string_literal: true

# Scan the repo's media/ directory for user-dropped image files and
# link them into the matching game's media[] entry.
#
# This lets you collect covers manually (scan from your own boxes,
# download a public-domain image, take a photo of a cart, etc.) and
# have them picked up on the next build.
#
# Folder convention:
#   media/{kind}/{platform}/{filename}
#
#   kind     = boxart | boxart_back | titlescreen | screenshot |
#              cartridge | disc | logo
#   platform = fc | sfc | gb | gbc | gba | md | pce | n64 | nds | ps1
#   filename = {game_id}[-{region}][-{tag}].{ext}
#
#     ext     = png | jpg | jpeg | webp | gif
#     region  = jp | us | eu | kr | cn | tw | hk | au | br   (optional, default jp)
#     tag     = anything else, kept as part of the URL (optional)
#
# Examples:
#   media/boxart/gb/tv-champion.jpg                 -> region=jp
#   media/boxart/gb/tv-champion-us.jpg              -> region=us
#   media/boxart/gb/tv-champion-jp-rev1.jpg         -> region=jp, tag=rev1
#   media/titlescreen/fc/hoshi-no-kirby.png         -> region=jp
#   media/cartridge/sfc/final-fantasy-iv-jp.jpg     -> region=jp, kind=cartridge
#
# The image is served as a plain static asset via GitHub Pages; the
# URL written into media[] points at:
#   https://raw.githubusercontent.com/retronian/native-game-db/main/media/{kind}/{platform}/{filename}
#
# Usage:
#   ruby scripts/import_local_media.rb
#   ruby scripts/import_local_media.rb --dry-run

require 'json'
require 'optparse'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
MEDIA_DIR = File.join(ROOT, 'media')

# Must match the raw base URL the repo is served from. GitHub Pages
# serves dist/ at https://gamedb.retronian.com/, but media/ lives in
# the repo root (not in dist/), so we link to raw.githubusercontent.
RAW_BASE = 'https://raw.githubusercontent.com/retronian/native-game-db/main/media'

VALID_KINDS = %w[boxart boxart_back titlescreen screenshot cartridge disc logo].freeze
VALID_PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1].freeze
VALID_REGIONS = %w[jp us eu kr cn tw hk au br].freeze
VALID_EXT = %w[.png .jpg .jpeg .webp .gif].freeze

# Parse filename into [game_id, region, tag]
# Rule: strip extension, split by "-". Find the first "-{region}" match
#       (where region is in VALID_REGIONS) and split there. Everything
#       before it is the game id; everything after is the tag.
#       If no region suffix, default to jp and tag is anything after
#       the game id (but then we can't know where the id ends, so the
#       whole stem is the id).
def parse_filename(stem)
  parts = stem.split('-')
  region = nil
  region_pos = nil
  parts.each_with_index do |p, i|
    next if i.zero?  # id must be at least one segment
    if VALID_REGIONS.include?(p)
      region = p
      region_pos = i
      break
    end
  end
  if region
    id  = parts[0...region_pos].join('-')
    tag = parts[(region_pos + 1)..].join('-')
    tag = nil if tag.nil? || tag.empty?
  else
    id = stem
    region = 'jp'  # default
    tag = nil
  end
  [id, region, tag]
end

def walk_media
  return [] unless Dir.exist?(MEDIA_DIR)
  files = []
  Dir.glob(File.join(MEDIA_DIR, '**', '*')).each do |path|
    next unless File.file?(path)
    rel = path.sub("#{MEDIA_DIR}/", '')
    parts = rel.split('/')
    next unless parts.size == 3  # kind/platform/filename
    kind, platform, filename = parts
    next unless VALID_KINDS.include?(kind)
    next unless VALID_PLATFORMS.include?(platform)
    ext = File.extname(filename).downcase
    next unless VALID_EXT.include?(ext)
    stem = File.basename(filename, ext)
    id, region, tag = parse_filename(stem)
    files << { kind: kind, platform: platform, id: id, region: region, tag: tag,
               filename: filename, rel: rel }
  end
  files
end

def main
  options = { dry_run: false }
  OptionParser.new do |o|
    o.banner = 'Usage: ruby scripts/import_local_media.rb [--dry-run]'
    o.on('--dry-run') { options[:dry_run] = true }
  end.parse!

  entries = walk_media
  puts "Found #{entries.size} image files under media/"

  added = 0
  missing_game = 0
  already_present = 0
  per_platform = Hash.new(0)

  entries.each do |e|
    game_path = File.join(SRC, e[:platform], "#{e[:id]}.json")
    unless File.exist?(game_path)
      warn "  MISS: no game entry for #{e[:platform]}/#{e[:id]} (from #{e[:rel]})"
      missing_game += 1
      next
    end
    game = JSON.parse(File.read(game_path))
    url = "#{RAW_BASE}/#{e[:rel]}"

    game['media'] ||= []
    if game['media'].any? { |m| m['url'] == url }
      already_present += 1
      next
    end

    # If a same kind+region entry from another source exists, we still
    # append ours — the UI shows every regional variant, so multiple
    # "boxart jp" entries coexist.
    media_entry = {
      'kind'   => e[:kind],
      'url'    => url,
      'region' => e[:region],
      'source' => 'manual',
      'verified' => true
    }
    media_entry['variant'] = e[:tag] if e[:tag] && !VALID_REGIONS.include?(e[:tag])
    # Note: 'variant' is not in the schema, keep media minimal.
    media_entry.delete('variant')

    game['media'] << media_entry
    puts "  + #{e[:platform]}/#{e[:id]}  kind=#{e[:kind]} region=#{e[:region]}#{e[:tag] ? " tag=#{e[:tag]}" : ''}"
    File.write(game_path, JSON.pretty_generate(game) + "\n") unless options[:dry_run]
    added += 1
    per_platform[e[:platform]] += 1
  end

  puts
  puts "Summary:"
  puts "  added:           #{added}"
  puts "  already present: #{already_present}"
  puts "  missing entry:   #{missing_game}"
  per_platform.sort.each { |pf, n| puts "    #{pf}: #{n}" }
  puts "  (dry run — no files written)" if options[:dry_run]
end

main if __FILE__ == $PROGRAM_NAME
