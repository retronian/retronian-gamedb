#!/usr/bin/env ruby
# frozen_string_literal: true

# Second-pass cover fetcher that targets Japanese-release entries whose
# JP boxart is missing after the primary scripts/fetch_covers.rb run.
#
# The primary script matches thumbnail filenames to No-Intro rom names
# 1:1. libretro-thumbnails often stores JP covers under a romanised
# Japanese name that does not match the English-market No-Intro name
# (for instance "Chocobo no Fushigi na Dungeon 2 (Japan, Asia)" vs
# rom "Chocobo's Dungeon 2 - Incredible Adventure (Japan)"), so that
# pass misses them. This script does:
#
#   1. Build an index of every (Japan)-suffixed thumbnail per platform,
#      keyed by slug and by hyphen-collapsed slug. libretro escapes "&"
#      as " _ " in filenames, so we register both the " _ " and the
#      "&" / "and" forms.
#   2. For each game that has a JP retail rom but no region=jp boxart
#      in media[], try slug candidates derived from the game id, every
#      rom name and every title, plus any manual alias in
#      data/media_aliases.json.
#   3. Append matched thumbnails to media[] with region=jp and
#      source=libretro_thumbnails (or source=manual_alias if resolved
#      through the alias map).
#
# Usage:
#   ruby scripts/fetch_jp_covers.rb
#   ruby scripts/fetch_jp_covers.rb --platform gb
#   ruby scripts/fetch_jp_covers.rb --dry-run

require 'json'
require 'open3'
require 'cgi'
require 'optparse'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/slug'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
ALIAS_FILE = File.join(ROOT, 'data', 'media_aliases.json')
LIBRETRO_RAW = 'https://raw.githubusercontent.com/libretro-thumbnails'
TREE_CACHE = File.join(Dir.tmpdir, 'retronian-gamedb-lrt')

FileUtils.mkdir_p(TREE_CACHE)

REPOS = {
  'fc'  => %w[Nintendo_-_Nintendo_Entertainment_System],
  'sfc' => %w[Nintendo_-_Super_Nintendo_Entertainment_System],
  'gb'  => %w[Nintendo_-_Game_Boy],
  'gbc' => %w[Nintendo_-_Game_Boy_Color],
  'gba' => %w[Nintendo_-_Game_Boy_Advance],
  'md'  => %w[Sega_-_Mega_Drive_-_Genesis],
  'pce' => %w[NEC_-_PC_Engine_-_TurboGrafx_16 NEC_-_PC_Engine_CD_-_TurboGrafx-CD],
  'n64' => %w[Nintendo_-_Nintendo_64],
  'nds' => %w[Nintendo_-_Nintendo_DS],
  'ps1' => %w[Sony_-_PlayStation]
}.freeze

KIND_DIRS = {
  'boxart'      => 'Named_Boxarts',
  'titlescreen' => 'Named_Titles',
  'screenshot'  => 'Named_Snaps'
}.freeze

NON_RETAIL_ROM_RE = /\((?:Proto|Possible Proto|Beta|Unl|Pirate|Sample|Demo|Hack|Aftermarket|Homebrew)(?:\s+\d+)?\)/i.freeze

def load_aliases
  return {} unless File.exist?(ALIAS_FILE)
  JSON.parse(File.read(ALIAS_FILE)).dig('libretro_thumbnails') || {}
end

def fetch_tree(repo)
  cache_path = File.join(TREE_CACHE, "#{repo}.json")
  if File.exist?(cache_path) && (Time.now - File.mtime(cache_path)) < 86_400
    return JSON.parse(File.read(cache_path))
  end

  %w[master main].each do |branch|
    out, _, status = Open3.capture3('gh', 'api',
                                    "repos/libretro-thumbnails/#{repo}/git/trees/#{branch}?recursive=1")
    next unless status.success? && !out.empty?
    data = JSON.parse(out)
    next unless data['tree']
    payload = { 'branch' => branch, 'tree' => data['tree'] }
    File.write(cache_path, JSON.generate(payload))
    return payload
  end
  nil
end

def build_jp_index(tree_payload, repo)
  branch = tree_payload['branch']
  index = { 'boxart' => {}, 'titlescreen' => {}, 'screenshot' => {}, 'by_filename' => {} }
  tree_payload['tree'].each do |node|
    next unless node['type'] == 'blob'
    path = node['path']
    KIND_DIRS.each do |kind, dir|
      next unless path.start_with?("#{dir}/") && path.end_with?('.png')
      filename = path.sub("#{dir}/", '').sub(/\.png\z/, '')
      entry = { path: path, branch: branch, repo: repo, filename: filename, kind: kind }
      index['by_filename']["#{kind}/#{filename}"] = entry
      # only want Japan variants for index keys we auto-match on
      next unless filename =~ /\(Japan(?:,\s*(?:Asia|USA|Europe))*\)/i
      base = filename.sub(/\s*\([^)]+\).*\z/, '')
      # libretro escapes "&" as " _ " in filenames.
      bases = [base]
      bases << base.gsub(' _ ', ' & ') if base.include?(' _ ')
      bases.uniq.each do |b|
        Slug.aliases_for(b).each do |a|
          index[kind][a] ||= entry
          index[kind][a.gsub('-', '')] ||= entry
        end
      end
    end
  end
  index
end

def url_for(repo, branch, path)
  "#{LIBRETRO_RAW}/#{repo}/#{branch}/#{path.split('/').map { |p| CGI.escape(p).gsub('+', '%20') }.join('/')}"
end

def japanese_release?(game)
  return false if game['id'].to_s.start_with?('bios-')
  return false if (game['category'] || '') == 'bios'
  (game['roms'] || []).any? do |r|
    r['region'] == 'jp' && r['name'].to_s !~ NON_RETAIL_ROM_RE
  end
end

def candidate_slugs(game)
  list = [game['id']]
  (game['roms'] || []).each do |r|
    base = Slug.strip_no_intro_suffixes(r['name'].to_s)
    list << Slug.slugify(base)
    list += Slug.aliases_for(base)
  end
  (game['titles'] || []).each do |t|
    list += Slug.aliases_for(t['text'])
  end
  list += list.map { |c| c&.gsub('-', '') }
  list.compact.uniq
end

def process_platform(pf, aliases, dry_run:)
  repos = REPOS[pf]
  return { added: 0, touched: 0 } unless repos

  puts "=== #{pf} ==="
  merged = { 'boxart' => {}, 'titlescreen' => {}, 'screenshot' => {}, 'by_filename' => {} }
  repos.each do |repo|
    puts "  fetching tree: #{repo}"
    tree = fetch_tree(repo)
    next unless tree
    idx = build_jp_index(tree, repo)
    idx.each { |k, h| merged[k].merge!(h) { |_, old, _| old } }
  end

  pf_aliases = aliases[pf] || {}

  added = 0
  touched = 0
  Dir.glob(File.join(SRC, pf, '*.json')).sort.each do |path|
    game = JSON.parse(File.read(path))
    next unless japanese_release?(game)

    media = game['media'] ||= []
    next if media.any? { |m| m['kind'] == 'boxart' && m['region'] == 'jp' }

    # Pick candidate filename hits. Priority: manual alias > auto slug match.
    hits = {} # kind => entry
    manual_source = false
    if pf_aliases[game['id']]
      manual_filename = pf_aliases[game['id']]
      manual_source = true
      KIND_DIRS.each_key do |kind|
        key = "#{kind}/#{manual_filename}"
        hits[kind] = merged['by_filename'][key] if merged['by_filename'][key]
      end
    end

    if hits.empty?
      candidates = candidate_slugs(game)
      KIND_DIRS.each_key do |kind|
        next if hits[kind]
        candidates.each do |c|
          hit = merged[kind][c]
          if hit
            hits[kind] = hit
            break
          end
        end
      end
    end

    this_added = 0
    hits.each do |kind, entry|
      url = url_for(entry[:repo], entry[:branch], entry[:path])
      next if media.any? { |m| m['url'] == url }
      next if media.any? { |m| m['kind'] == kind && m['region'] == 'jp' }
      media << {
        'kind' => kind, 'url' => url,
        'source' => manual_source ? 'manual_alias' : 'libretro_thumbnails',
        'region' => 'jp'
      }
      this_added += 1
      added += 1
    end

    if this_added.positive?
      File.write(path, JSON.pretty_generate(game) + "\n") unless dry_run
      touched += 1
    end
  end

  puts "  added #{added} media across #{touched} games"
  { added: added, touched: touched }
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |o|
    o.banner = 'Usage: ruby scripts/fetch_jp_covers.rb [options]'
    o.on('--dry-run') { options[:dry_run] = true }
    o.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  aliases = load_aliases
  platforms = options[:platform] ? [options[:platform]] : REPOS.keys

  grand = { added: 0, touched: 0 }
  platforms.each do |pf|
    r = process_platform(pf, aliases, dry_run: options[:dry_run])
    grand[:added] += r[:added]
    grand[:touched] += r[:touched]
  end
  puts
  puts "TOTAL: +#{grand[:added]} media across #{grand[:touched]} games#{options[:dry_run] ? ' (dry-run)' : ''}"
end

main if __FILE__ == $PROGRAM_NAME
