#!/usr/bin/env ruby
# frozen_string_literal: true

# Keep only games that have at least one *retail* No-Intro ROM. Anything
# else — pure prototypes, betas, unlicensed dumps, pirate carts,
# samples, demos, hacks, aftermarket releases, homebrew — gets
# deleted.
#
# This is the policy decision: native-game-db tracks commercially
# released titles. IGDB-derived orphan entries (no roms[] at all) are
# also removed because we have no evidence that they were ever sold.
#
# Usage:
#   ruby scripts/purge_non_commercial.rb              # all platforms
#   ruby scripts/purge_non_commercial.rb --dry-run
#   ruby scripts/purge_non_commercial.rb --platform fc

require 'json'
require 'optparse'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')

NON_RETAIL_RE = /\((?:Proto|Possible Proto|Beta|Unl|Pirate|Sample|Demo|Hack|Aftermarket|Homebrew|Test|Debug|Prototype)\)/i.freeze

# Sources we trust as evidence that a title was actually released
# commercially. The IGDB source is intentionally excluded — IGDB also
# tracks prototypes, mods and homebrew, so an entry whose only
# evidence is IGDB is not enough.
TRUSTED_TITLE_SOURCES = %w[
  wikidata wikipedia_ja wikipedia_en wikipedia_ko wikipedia_zh
  wikipedia_fr wikipedia_es wikipedia_de wikipedia_it wikipedia_pt wikipedia_ru
  romu gamelist_ja skyscraper_ja no_intro manual
].freeze

def commercial?(game)
  roms = game['roms'] || []

  if roms.any?
    # If we have ROM evidence, require at least one retail rom.
    return roms.any? { |r| !r['name'].to_s.match?(NON_RETAIL_RE) }
  end

  # No ROM evidence: fall back to title source. Wikipedia/Wikidata/romu
  # only catalogue commercial releases, so any title from those
  # sources counts.
  game['titles'].any? { |t| TRUSTED_TITLE_SOURCES.include?(t['source']) }
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  glob = if options[:platform]
           File.join(SRC, options[:platform], '*.json')
         else
           File.join(SRC, '*', '*.json')
         end

  totals = Hash.new(0)
  per_platform = Hash.new { |h, k| h[k] = { kept: 0, removed: 0 } }

  Dir.glob(glob).sort.each do |path|
    game = JSON.parse(File.read(path))
    pf = game['platform']
    totals[:files] += 1

    if commercial?(game)
      per_platform[pf][:kept] += 1
      totals[:kept] += 1
    else
      per_platform[pf][:removed] += 1
      totals[:removed] += 1
      File.delete(path) unless options[:dry_run]
    end
  end

  puts '=== purge_non_commercial ==='
  per_platform.sort_by { |k, _| k }.each do |pf, s|
    total = s[:kept] + s[:removed]
    pct = total.positive? ? (s[:removed] * 100.0 / total).round(1) : 0
    puts "  #{pf.ljust(5)} kept #{s[:kept].to_s.rjust(5)}  removed #{s[:removed].to_s.rjust(5)}  (#{pct}% removed)"
  end
  puts
  totals.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
