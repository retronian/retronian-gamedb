#!/usr/bin/env ruby
# frozen_string_literal: true

# Import arcade-style shortname ROMs from a FinalBurn Neo DAT into
# retronian-gamedb. This creates one game entry per local ZIP shortname,
# using the DAT description as the English title and an optional CSV for
# Japanese display titles.
#
# Usage:
#   ruby scripts/import_fbneo_dat.rb --dat path/to/fbneo.dat --rom-root ~/Roms/android-english-roms
#   ruby scripts/import_fbneo_dat.rb --platform neogeo --dry-run

require 'csv'
require 'fileutils'
require 'json'
require 'optparse'
require 'rexml/document'
require_relative 'lib/script_detector'
require_relative 'lib/slug'

ROOT = File.expand_path('..', __dir__)
SRC = File.join(ROOT, 'data', 'games')
DEFAULT_ROM_ROOT = File.expand_path('~/Roms/android-english-roms')
DEFAULT_DAT = File.join(ROOT, 'tmp', 'fbneo-arcade.dat')
DEFAULT_TITLES = File.join(ROOT, 'data', 'imports', 'fbneo_titles_ja.csv')

FOLDERS = {
  'arcade' => 'arcade',
  'cps3' => 'cps3',
  'neogeo' => 'neogeo'
}.freeze

def clean_english_title(desc)
  text = desc.to_s.sub(/\s*\([^)]*\)\s*\z/, '').strip
  text.empty? ? desc.to_s.strip : text
end

def load_dat(path)
  abort "DAT not found: #{path}" unless File.exist?(path)
  doc = REXML::Document.new(File.read(path))
  out = {}
  doc.elements.each('datafile/game') do |game|
    name = game.attributes['name'].to_s
    desc = game.elements['description']&.text.to_s
    next if name.empty? || desc.empty?
    out[name] = clean_english_title(desc)
  end
  out
end

def load_ja_titles(path)
  return {} unless File.exist?(path)
  out = {}
  CSV.foreach(path, headers: true) do |row|
    platform = row['platform'].to_s
    rom = row['rom'].to_s.sub(/\.zip\z/i, '')
    title = row['ja_title'].to_s.strip
    next if platform.empty? || rom.empty? || title.empty?
    out[[platform, rom]] = title
  end
  out
end

def rom_shortnames(root, platform)
  dir = File.join(root, FOLDERS.fetch(platform))
  Dir.glob(File.join(dir, '*.zip')).map { |p| File.basename(p, '.zip') }.sort
end

def game_id(platform, shortname, en_title)
  base = Slug.slugify(en_title) || shortname
  "#{base}-#{shortname}".gsub(/-+/, '-')
end

def build_game(platform, shortname, en_title, ja_title)
  titles = []
  if ja_title && !ja_title.empty?
    titles << {
      'text' => ja_title,
      'lang' => 'ja',
      'script' => ScriptDetector.detect(ja_title),
      'region' => 'jp',
      'form' => 'official',
      'source' => 'manual',
      'verified' => false
    }
  end
  titles << {
    'text' => en_title,
    'lang' => 'en',
    'script' => 'Latn',
    'form' => 'official',
    'source' => 'fbneo',
    'verified' => false
  }
  {
    'id' => game_id(platform, shortname, en_title),
    'platform' => platform,
    'category' => 'main_game',
    'titles' => titles,
    'roms' => [
      {
        'name' => "#{shortname}.zip",
        'source' => 'fbneo'
      }
    ]
  }
end

def main
  options = {
    dat: DEFAULT_DAT,
    rom_root: DEFAULT_ROM_ROOT,
    titles: DEFAULT_TITLES,
    platform: nil,
    dry_run: false
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/import_fbneo_dat.rb [options]'
    opts.on('--dat PATH') { |v| options[:dat] = File.expand_path(v) }
    opts.on('--rom-root PATH') { |v| options[:rom_root] = File.expand_path(v) }
    opts.on('--titles PATH') { |v| options[:titles] = File.expand_path(v) }
    opts.on('--platform ID') { |v| options[:platform] = v }
    opts.on('--dry-run') { options[:dry_run] = true }
  end.parse!

  dat = load_dat(options[:dat])
  ja_titles = load_ja_titles(options[:titles])
  platforms = options[:platform] ? [options[:platform]] : FOLDERS.keys

  platforms.each do |platform|
    abort "unknown platform: #{platform}" unless FOLDERS.key?(platform)
    out_dir = File.join(SRC, platform)
    FileUtils.mkdir_p(out_dir) unless options[:dry_run]

    stats = Hash.new(0)
    rom_shortnames(options[:rom_root], platform).each do |shortname|
      next if shortname == 'neogeo'

      en_title = dat[shortname]
      if en_title.nil?
        if ja_titles[[platform, shortname]]
          en_title = shortname
          stats[:missing_dat_fallback] += 1
        else
          stats[:missing_dat] += 1
          next
        end
      end
      game = build_game(platform, shortname, en_title, ja_titles[[platform, shortname]])
      path = File.join(out_dir, "#{game['id']}.json")
      stats[:with_ja] += 1 if ja_titles[[platform, shortname]]
      stats[:written] += 1
      File.write(path, JSON.pretty_generate(game) + "\n") unless options[:dry_run]
    end
    puts "#{platform}: #{stats.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  end
end

main if __FILE__ == $PROGRAM_NAME
