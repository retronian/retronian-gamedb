#!/usr/bin/env ruby
# frozen_string_literal: true

# Attach cover art and title screen URLs from libretro-thumbnails.
#
# libretro-thumbnails is a monorepo-of-submodules project where each
# retro platform lives in its own GitHub repository named with
# underscores, e.g.:
#   libretro-thumbnails/Nintendo_-_Game_Boy
#   libretro-thumbnails/Sega_-_Mega_Drive_-_Genesis
#
# Every repo has Named_Boxarts/, Named_Snaps/ and Named_Titles/
# directories, each holding PNGs whose filename is the No-Intro ROM
# name plus ".png". We fetch the full tree per repo once, then walk
# each native-game-db entry and stitch up media[] URLs for every
# rom[i].name that has a matching thumbnail.
#
# Usage:
#   ruby scripts/fetch_covers.rb                  # all platforms
#   ruby scripts/fetch_covers.rb --platform gb
#   ruby scripts/fetch_covers.rb --dry-run

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'optparse'
require 'cgi'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
LIBRETRO = 'https://raw.githubusercontent.com/libretro-thumbnails'

# Map native-game-db platform id -> libretro-thumbnails repo(s).
# Most platforms are a single repo; ngp has two variants (Neo Geo
# Pocket and Neo Geo Pocket Color) so we take both.
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

# Fetch the complete file tree for a repo. Returns the set of filename
# stems (without .png) that exist under each kind dir.
def fetch_repo_index(repo)
  # Try the default branch first via the /git/trees endpoint. libretro
  # uses "master" for thumbnail repos. If that fails, fall back to "main".
  %w[master main].each do |branch|
    out = `gh api repos/libretro-thumbnails/#{repo}/git/trees/#{branch}?recursive=1 2>/dev/null`
    next unless $?.success? && !out.empty?
    data = JSON.parse(out)
    next if data['tree'].nil?

    index = { 'boxart' => {}, 'titlescreen' => {}, 'screenshot' => {} }
    data['tree'].each do |node|
      next unless node['type'] == 'blob'
      path = node['path']
      KIND_DIRS.each do |kind, dir|
        if path.start_with?("#{dir}/") && path.end_with?('.png')
          filename = path.sub("#{dir}/", '').sub(/\.png\z/, '')
          index[kind][filename] = path
        end
      end
    end
    return { branch: branch, index: index }
  end
  nil
end

def url_for(repo, branch, repo_path)
  encoded = repo_path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')
  "#{LIBRETRO}/#{repo}/#{branch}/#{encoded}"
end

def add_media_if_new(media, incoming)
  return :duplicate if media.any? { |m| m['url'] == incoming['url'] }
  media << incoming
  :added
end

def process_platform(platform_id, dry_run:)
  repos = REPOS[platform_id]
  return nil if repos.nil? || repos.empty?

  # Fetch and merge all repo indices for this platform.
  combined_index = { 'boxart' => [], 'titlescreen' => [], 'screenshot' => [] }
  repos.each do |repo|
    puts "      #{repo}: fetching tree..."
    result = fetch_repo_index(repo)
    if result.nil?
      puts "      #{repo}: tree fetch failed"
      next
    end
    branch = result[:branch]
    result[:index].each do |kind, files|
      files.each do |filename, repo_path|
        combined_index[kind] << { filename: filename, repo: repo, branch: branch, repo_path: repo_path }
      end
    end
  end

  # Flatten to a simple filename -> [media entries] lookup per kind.
  by_kind = {}
  combined_index.each do |kind, entries|
    by_kind[kind] = {}
    entries.each do |e|
      by_kind[kind][e[:filename]] ||= e
    end
  end

  # Walk native-game-db games on this platform.
  dir = File.join(SRC, platform_id)
  return nil unless Dir.exist?(dir)

  per = Hash.new(0)
  region_suffixes = ['', ' (Japan)', ' (USA)', ' (Europe)', ' (USA, Europe)',
                     ' (Japan, USA)', ' (World)', ' (Japan, USA, Europe)']

  Dir.glob(File.join(dir, '*.json')).sort.each do |path|
    game = JSON.parse(File.read(path))
    roms = game['roms'] || []

    game['media'] ||= []
    touched = false

    # Primary path: match every rom's No-Intro name.
    roms.each do |rom|
      filename = rom['name']
      KIND_DIRS.each_key do |kind|
        hit = by_kind[kind][filename]
        next unless hit
        url = url_for(hit[:repo], hit[:branch], hit[:repo_path])
        incoming = { 'kind' => kind, 'url' => url, 'source' => 'libretro_thumbnails' }
        incoming['region'] = rom['region'] if rom['region']
        r = add_media_if_new(game['media'], incoming)
        touched = true if r == :added
        per[r] += 1
      end
    end

    # Fallback: if no rom-based matches, try English titles + common
    # region suffixes.
    if !touched
      suffix_to_region = {
        ' (Japan)'               => 'jp',
        ' (USA)'                 => 'us',
        ' (Europe)'              => 'eu',
        ' (USA, Europe)'         => 'us',
        ' (Japan, USA)'          => 'jp',
        ' (Japan, USA, Europe)'  => 'jp',
        ' (World)'               => nil
      }
      en_titles = game['titles'].select { |t| t['lang'] == 'en' && t['script'] == 'Latn' }
                                .map    { |t| t['text'] }.uniq
      en_titles.each do |title|
        region_suffixes.each do |suffix|
          filename = "#{title}#{suffix}"
          KIND_DIRS.each_key do |kind|
            hit = by_kind[kind][filename]
            next unless hit
            url = url_for(hit[:repo], hit[:branch], hit[:repo_path])
            incoming = { 'kind' => kind, 'url' => url, 'source' => 'libretro_thumbnails' }
            region = suffix_to_region[suffix]
            incoming['region'] = region if region
            r = add_media_if_new(game['media'], incoming)
            touched = true if r == :added
            per[r] += 1
          end
        end
      end
    end

    game.delete('media') if game['media'].empty?

    if touched && !dry_run
      File.write(path, JSON.pretty_generate(game) + "\n")
    end

    per[:games_touched] += 1 if touched
  end

  per
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/fetch_covers.rb [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  puts '=== libretro-thumbnails cover fetch ==='
  puts

  overall = Hash.new(0)
  platforms = options[:platform] ? [options[:platform]] : REPOS.keys
  platforms.each do |platform_id|
    puts "  #{platform_id}"
    stats = process_platform(platform_id, dry_run: options[:dry_run])
    if stats.nil?
      puts '      skipped'
      next
    end
    summary = stats.map { |k, v| "#{k}=#{v}" }.join(', ')
    puts "      #{summary.empty? ? '(no hits)' : summary}"
    stats.each { |k, v| overall[k] += v }
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
