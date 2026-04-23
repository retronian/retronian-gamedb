#!/usr/bin/env ruby
# frozen_string_literal: true

# Ingest a contributor-filed GitHub issue into a data change.
#
# Takes an issue number (or URL), pulls the structured form fields from
# the body via `gh issue view`, and either:
#   - for media issues: downloads the attached image into media/ and
#     runs scripts/import_local_media.rb to link it
#   - for title issues: appends a title to the matching game's titles[]
#
# After running, review `git status`, commit, and push (or open a PR).
# The issue can then be closed with "Applied in <commit>".
#
# Requires: `gh` CLI authenticated against retronian/native-game-db.
#
# Usage:
#   ruby scripts/ingest_issue.rb 42
#   ruby scripts/ingest_issue.rb https://github.com/retronian/native-game-db/issues/42
#   ruby scripts/ingest_issue.rb 42 --dry-run

require 'json'
require 'open3'
require 'uri'
require 'fileutils'
require 'optparse'
require_relative 'lib/script_detector'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')
MEDIA_DIR = File.join(ROOT, 'media')
REPO = 'retronian/native-game-db'

def parse_issue_number(arg)
  if arg =~ /\/issues\/(\d+)/
    Regexp.last_match(1)
  elsif arg =~ /\A\d+\z/
    arg
  else
    abort "Invalid issue reference: #{arg}"
  end
end

def fetch_issue(number)
  out, _, status = Open3.capture3('gh', 'issue', 'view', number, '--repo', REPO,
                                  '--json', 'number,title,body,labels,author')
  abort "Failed to fetch issue ##{number}" unless status.success?
  JSON.parse(out)
end

# GitHub issue forms render each answer as:
#   ### Field label
#
#   value
#
# or for textarea:
#   ### Field label
#
#   value
#   (possibly multiline)
#
# Parse by splitting on "### " headings.
def parse_form_body(body)
  sections = body.split(/^### /)
  fields = {}
  sections[1..].to_a.each do |section|
    lines = section.strip.split("\n", 2)
    label = lines[0].to_s.strip
    value = lines[1].to_s.strip
    # "_No response_" means the user left it empty.
    value = nil if value == '_No response_' || value.empty?
    fields[label] = value
  end
  fields
end

def find_field(fields, *aliases)
  aliases.each do |alias_name|
    fields.each do |k, v|
      return v if k.start_with?(alias_name) || k.include?(alias_name)
    end
  end
  nil
end

def download_image(url, dest)
  uri = URI(url)
  # GitHub issue image uploads are on user-images.githubusercontent.com or
  # private-user-images.githubusercontent.com; both public via HTTPS.
  system('curl', '-sL', '-o', dest, uri.to_s) or abort "download failed: #{url}"
end

def guess_ext(url)
  ext = File.extname(URI(url).path).downcase
  %w[.png .jpg .jpeg .webp .gif].include?(ext) ? ext : '.jpg'
end

def handle_media_issue(fields, dry_run:)
  platform = find_field(fields, 'Platform')&.strip
  game_id  = find_field(fields, 'Game ID')&.strip
  kind     = find_field(fields, 'Kind')&.strip
  region   = find_field(fields, 'Region')&.strip
  image    = find_field(fields, 'Image')&.strip
  abort "Missing platform/game_id/kind/region/image in issue body" unless platform && game_id && kind && region && image

  game_path = File.join(SRC, platform, "#{game_id}.json")
  abort "Game not found: #{game_path}" unless File.exist?(game_path)

  # Image field might contain:
  #   - a full https URL (the image was attached and GitHub rewrote it)
  #   - a markdown image: ![alt](URL)
  url = image[/https?:\/\/\S+/] or abort "No image URL found in issue body"
  url = url.sub(/[)>]+\z/, '')

  ext = guess_ext(url)
  filename = "#{game_id}#{region != 'jp' ? "-#{region}" : ''}#{ext}"
  target_dir = File.join(MEDIA_DIR, kind, platform)
  FileUtils.mkdir_p(target_dir) unless dry_run
  target = File.join(target_dir, filename)
  puts "  download #{url}"
  puts "       -> #{target}"
  unless dry_run
    download_image(url, target)
    puts "  run import_local_media.rb"
    system('ruby', 'scripts/import_local_media.rb', chdir: ROOT) or abort 'import failed'
  end
end

def handle_title_issue(fields, dry_run:)
  platform = find_field(fields, 'Platform')&.strip
  game_id  = find_field(fields, 'Game ID')&.strip
  text     = find_field(fields, 'Title text')&.strip
  lang     = find_field(fields, 'Language')&.strip
  script   = find_field(fields, 'Script')&.strip
  region   = find_field(fields, 'Region')&.strip
  form     = find_field(fields, 'Form')&.strip || 'official'
  source   = find_field(fields, 'Source')&.strip || 'community'
  verified = (find_field(fields, 'Verification') || '').include?('[X]')

  abort "Missing platform/game_id/text/lang/script/region" unless platform && game_id && text && lang && script && region

  game_path = File.join(SRC, platform, "#{game_id}.json")
  abort "Game not found: #{game_path}" unless File.exist?(game_path)
  game = JSON.parse(File.read(game_path))

  # If the user put a URL in source, keep it but normalize the source enum
  source_key = if source =~ /wikipedia\.org/i then 'wikipedia_ja'
               elsif source =~ /wikidata/i    then 'wikidata'
               else 'community'
               end

  # Auto-detect script if user said something unclear
  detected = ScriptDetector.detect(text)
  if script == 'Auto' || script.nil? || script.empty?
    script = detected
  end

  entry = {
    'text'     => text,
    'lang'     => lang,
    'script'   => script,
    'region'   => region,
    'form'     => form,
    'source'   => source_key,
    'verified' => verified
  }

  if game['titles'].any? { |t| t['lang'] == lang && t['text'] == text }
    puts "  title already present, skipping"
    return
  end

  game['titles'] << entry
  puts "  + #{platform}/#{game_id} ja title: #{script}/#{region} #{text.inspect}"
  File.write(game_path, JSON.pretty_generate(game) + "\n") unless dry_run
end

def main
  options = { dry_run: false }
  OptionParser.new do |o|
    o.banner = "Usage: ruby scripts/ingest_issue.rb ISSUE_NUMBER_OR_URL [--dry-run]"
    o.on('--dry-run') { options[:dry_run] = true }
  end.parse!

  abort "missing issue number" unless ARGV[0]
  number = parse_issue_number(ARGV[0])

  puts "== fetching issue ##{number} =="
  issue = fetch_issue(number)
  puts "  title: #{issue['title']}"
  puts "  by:    #{issue.dig('author', 'login')}"
  labels = issue['labels'].map { |l| l['name'] }
  puts "  labels: #{labels.inspect}"

  fields = parse_form_body(issue['body'])
  puts "  parsed #{fields.size} fields: #{fields.keys.inspect}"

  if labels.include?('media')
    handle_media_issue(fields, dry_run: options[:dry_run])
  elsif labels.include?('title')
    handle_title_issue(fields, dry_run: options[:dry_run])
  else
    abort "Unknown issue type (no 'media' or 'title' label)"
  end

  puts ''
  puts '== Next steps =='
  puts '  - Review `git status` / `git diff`'
  puts "  - Commit: git commit -am \"Apply #{labels.first} contribution from ##{number}\""
  puts '  - Push and close the issue with a reference to the commit.'
end

main if __FILE__ == $PROGRAM_NAME
