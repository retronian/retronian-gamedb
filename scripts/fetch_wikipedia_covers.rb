#!/usr/bin/env ruby
# frozen_string_literal: true

# Third-pass JP boxart fetcher: fill the gap left by fetch_covers.rb
# and fetch_jp_covers.rb by pulling the lead (infobox) image from
# Japanese / English Wikipedia via the REST v1 /page/summary endpoint.
#
# Why REST v1 instead of the plain pageimages API: pageimages only
# surfaces Commons-hosted or explicitly free files, so it cannot
# return retro-game box art (which Wikipedia stores locally under
# fair use). REST v1 summary returns the lead image regardless.
#
# Only entries whose Wikidata QID resolves to an actual Wikipedia
# article are queried, which keeps false matches out — unlike a
# title-search fallback which frequently returns unrelated articles
# (musicians, buildings, etc).
#
# Usage:
#   ruby scripts/fetch_wikipedia_covers.rb
#   ruby scripts/fetch_wikipedia_covers.rb --platform fc
#   ruby scripts/fetch_wikipedia_covers.rb --dry-run

require 'json'
require 'net/http'
require 'uri'
require 'cgi'
require 'optparse'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
USER_AGENT = 'native-game-db/0.1 (https://gamedb.retronian.com)'
NON_RETAIL_ROM_RE = /\((?:Proto|Possible Proto|Beta|Unl|Pirate|Sample|Demo|Hack|Aftermarket|Homebrew)\)/i.freeze

# Reject lead images that are clearly not box art: screenshots, title
# screens, generic hardware shots that appear on disambiguation/series
# articles, audio/video clips, etc.
NON_BOX_FILENAME_RE = /
  screenshot | gameplay | title[-_ ]?screen | in[-_ ]?game |
  \bmap\b | \bmenu\b | \bcast\b | character[-_ ]?art |
  console | system[-_ ]?set |
  \.svg$ | \.mp4$ | \.ogg$ | \.oga$ | \.webm$ | \.wav$
/ix.freeze

def http_get(uri)
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = USER_AGENT
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
end

def japanese_release?(game)
  return false if game['id'].to_s.start_with?('bios-')
  return false if (game['category'] || '') == 'bios'
  (game['roms'] || []).any? do |r|
    r['region'] == 'jp' && r['name'].to_s !~ NON_RETAIL_ROM_RE
  end
end

def resolve_wikipedia_articles(qids)
  ja = {}
  en = {}
  return [ja, en] if qids.empty?

  qids.uniq.each_slice(50) do |batch|
    sparql = <<~SPARQL
      SELECT ?qid ?ja ?en WHERE {
        VALUES ?qid { wd:#{batch.join(' wd:')} }
        OPTIONAL { ?ja schema:about ?qid ; schema:isPartOf <https://ja.wikipedia.org/> . }
        OPTIONAL { ?en schema:about ?qid ; schema:isPartOf <https://en.wikipedia.org/> . }
      }
    SPARQL
    uri = URI('https://query.wikidata.org/sparql')
    uri.query = URI.encode_www_form(query: sparql, format: 'json')
    res = http_get(uri)
    next unless res.is_a?(Net::HTTPSuccess)
    data = JSON.parse(res.body)
    data['results']['bindings'].each do |b|
      qid = b['qid']['value'].split('/').last
      if b['ja']
        ja[qid] ||= URI.decode_www_form_component(b['ja']['value'].sub('https://ja.wikipedia.org/wiki/', ''))
      end
      if b['en']
        en[qid] ||= URI.decode_www_form_component(b['en']['value'].sub('https://en.wikipedia.org/wiki/', ''))
      end
    end
    sleep 0.5
  end
  [ja, en]
end

def fetch_summary_image(lang, title)
  encoded = URI.encode_www_form_component(title.tr(' ', '_'))
  uri = URI("https://#{lang}.wikipedia.org/api/rest_v1/page/summary/#{encoded}")
  res = http_get(uri)
  return nil unless res.is_a?(Net::HTTPSuccess)
  data = JSON.parse(res.body)
  data.dig('originalimage', 'source') || data.dig('thumbnail', 'source')
rescue StandardError => e
  warn "  ! summary #{lang}/#{title}: #{e.message}"
  nil
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |o|
    o.banner = 'Usage: ruby scripts/fetch_wikipedia_covers.rb [options]'
    o.on('--dry-run') { options[:dry_run] = true }
    o.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  # Collect targets
  targets = []
  Dir.glob(File.join(SRC, '*', '*.json')).each do |f|
    g = JSON.parse(File.read(f))
    next if options[:platform] && g['platform'] != options[:platform]
    next unless japanese_release?(g)
    next if (g['media'] || []).any? { |m| m['kind'] == 'boxart' && m['region'] == 'jp' }
    qid = g.dig('external_ids', 'wikidata')
    next unless qid
    targets << { pf: g['platform'], id: g['id'], qid: qid, file: f }
  end
  puts "Targets (missing JP boxart, has QID): #{targets.size}"

  ja_article, en_article = resolve_wikipedia_articles(targets.map { |t| t[:qid] })
  puts "  resolved: ja=#{ja_article.size}, en=#{en_article.size}"

  added = 0
  skipped_nonbox = 0
  no_hit = 0

  targets.each do |t|
    image = nil
    source_tag = nil
    if ja_article[t[:qid]]
      image = fetch_summary_image('ja', ja_article[t[:qid]])
      source_tag = 'wikipedia_ja' if image
    end
    if image.nil? && en_article[t[:qid]]
      image = fetch_summary_image('en', en_article[t[:qid]])
      source_tag = 'wikipedia_en' if image
    end
    sleep 0.2

    if image.nil?
      no_hit += 1
      next
    end

    basename = URI.decode_www_form_component(image).split('/').last
    if basename =~ NON_BOX_FILENAME_RE
      skipped_nonbox += 1
      puts "  - #{t[:pf]}/#{t[:id]} skipped non-box: #{basename[0..50]}"
      next
    end

    g = JSON.parse(File.read(t[:file]))
    g['media'] ||= []
    next if g['media'].any? { |m| m['url'] == image }

    g['media'] << {
      'kind' => 'boxart', 'url' => image,
      'source' => source_tag, 'region' => 'jp',
      'verified' => false
    }
    puts "  + #{t[:pf]}/#{t[:id]} (#{source_tag}): #{basename[0..60]}"
    File.write(t[:file], JSON.pretty_generate(g) + "\n") unless options[:dry_run]
    added += 1
  end

  puts ''
  puts "Added: #{added}, skipped non-box: #{skipped_nonbox}, no hit: #{no_hit}#{options[:dry_run] ? ' (dry-run)' : ''}"
end

main if __FILE__ == $PROGRAM_NAME
