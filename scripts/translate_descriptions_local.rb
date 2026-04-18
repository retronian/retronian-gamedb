#!/usr/bin/env ruby
# frozen_string_literal: true

# Translate English descriptions[] entries to Japanese using a local
# ollama model. The result is appended as a new descriptions[] entry
# with source: ai_local_<model> and base_lang: en, so the original
# English source stays intact and the translation is clearly marked.
#
# Why local: we are about to fire ~14000 LLM requests, which would be
# expensive against a hosted API. ollama on the local 4060 is free
# and good enough.
#
# Why Japanese only: the European wiki extracts already cover most
# of fr/de/es/it/pt/ru. Korean and Chinese have very thin Wikipedia
# coverage and would need a separate pass.
#
# Resumability: a checkpoint file lists every (platform, id) we have
# already touched. Re-running the script picks up where it left off.
#
# Usage:
#   ruby scripts/translate_descriptions_local.rb               # all platforms
#   ruby scripts/translate_descriptions_local.rb --platform gb
#   ruby scripts/translate_descriptions_local.rb --limit 50
#   ruby scripts/translate_descriptions_local.rb --target ja --model gemma4:e4b
#
# Environment:
#   OLLAMA_HOST   defaults to http://localhost:11434

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'fileutils'
require_relative 'lib/script_detector'

$stdout.sync = true

ROOT       = File.expand_path('..', __dir__)
SRC        = File.join(ROOT, 'data', 'games')
CHECKPOINT = File.join(ROOT, '.translate_checkpoint.json')

OLLAMA = ENV['OLLAMA_HOST'] || 'http://localhost:11434'
MODEL  = 'gemma4:e4b'
TARGET = 'ja'

PLATFORMS = %w[fc sfc gb gbc gba md pce n64 nds ps1 vb ngp gg ms].freeze

LANG_NAMES = {
  'ja' => 'Japanese', 'ko' => 'Korean', 'zh' => 'Chinese',
  'fr' => 'French',   'es' => 'Spanish', 'de' => 'German',
  'it' => 'Italian',  'pt' => 'Portuguese', 'ru' => 'Russian'
}.freeze

# ---------- ollama ----------

def ollama_generate(prompt, model)
  uri = URI("#{OLLAMA}/api/generate")
  body = {
    model: model,
    prompt: prompt,
    stream: false,
    options: { temperature: 0.1, num_ctx: 4096, num_predict: 2048 }
  }.to_json
  req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  req.body = body
  res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 240) { |http| http.request(req) }
  return nil unless res.code == '200'
  JSON.parse(res.body)['response']&.strip
rescue StandardError => e
  warn "    ollama error: #{e.message}"
  nil
end

def build_prompt(text, target_name, native_title)
  glossary = native_title ? "The game's official Japanese title is #{native_title}." : ''
  <<~PROMPT
    Translate the following English text to natural #{target_name}. #{glossary}
    Output only the translation, no preamble, no quotes, no notes.

    #{text}
  PROMPT
end

# ---------- description selection ----------

def already_translated?(game, target, source_tag)
  (game['descriptions'] || []).any? { |d| d['lang'] == target && d['source'] == source_tag }
end

def has_native_description?(game, target)
  (game['descriptions'] || []).any? { |d| d['lang'] == target && !d['source'].to_s.start_with?('ai_local_') }
end

def best_en_description(game)
  descs = (game['descriptions'] || []).select { |d| d['lang'] == 'en' && !d['text'].to_s.strip.empty? }
  return nil if descs.empty?
  # Prefer the longest description so we have rich content to translate.
  descs.max_by { |d| d['text'].length }
end

def native_title_text(game, target)
  native_scripts = case target
                   when 'ja' then %w[Jpan Hira Kana]
                   when 'ko' then %w[Hang Kore]
                   when 'zh' then %w[Hans Hant]
                   else []
                   end
  return nil if native_scripts.empty?
  game['titles'].find { |t| t['lang'] == target && native_scripts.include?(t['script']) }&.dig('text')
end

# ---------- checkpoint ----------

def load_checkpoint
  return {} unless File.exist?(CHECKPOINT)
  JSON.parse(File.read(CHECKPOINT))
rescue StandardError
  {}
end

def save_checkpoint(cp)
  File.write(CHECKPOINT, JSON.pretty_generate(cp))
end

# ---------- main ----------

def main
  options = { platform: nil, limit: nil, model: MODEL, target: TARGET, dry_run: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/translate_descriptions_local.rb [options]'
    opts.on('--platform ID') { |p| options[:platform] = p }
    opts.on('--limit N', Integer) { |n| options[:limit] = n }
    opts.on('--model NAME')  { |m| options[:model] = m }
    opts.on('--target LANG') { |l| options[:target] = l }
    opts.on('--dry-run')     { options[:dry_run] = true }
  end.parse!

  target_name = LANG_NAMES[options[:target]] || options[:target]
  source_tag = "ai_local_#{options[:model].split(':').first.gsub(/[^a-z0-9]/i, '_')}"

  puts "=== translate_descriptions_local ==="
  puts "  model:    #{options[:model]}"
  puts "  target:   #{options[:target]} (#{target_name})"
  puts "  src tag:  #{source_tag}"
  puts

  cp = load_checkpoint
  cp[options[:target]] ||= {}

  platforms = options[:platform] ? [options[:platform]] : PLATFORMS
  candidates = []

  platforms.each do |pf|
    Dir.glob(File.join(SRC, pf, '*.json')).sort.each do |path|
      game = JSON.parse(File.read(path))
      next if has_native_description?(game, options[:target])  # already covered
      next if already_translated?(game, options[:target], source_tag) # done last run
      next if cp[options[:target]][game['id']]                  # checkpointed
      en = best_en_description(game)
      next unless en
      candidates << { path: path, game: game, en_text: en['text'] }
    end
  end

  candidates = candidates.first(options[:limit]) if options[:limit]
  puts "  candidates: #{candidates.size}"
  puts

  start = Time.now
  done  = 0

  candidates.each_with_index do |c, i|
    nt = native_title_text(c[:game], options[:target])
    prompt = build_prompt(c[:en_text], target_name, nt)

    t0 = Time.now
    translation = ollama_generate(prompt, options[:model])
    elapsed = Time.now - t0

    unless translation && !translation.empty?
      puts "  [#{i + 1}/#{candidates.size}] #{c[:game]['id']} (#{elapsed.round(1)}s)  FAILED"
      next
    end

    c[:game]['descriptions'] ||= []
    c[:game]['descriptions'] << {
      'text'      => translation,
      'lang'      => options[:target],
      'source'    => source_tag,
      'base_lang' => 'en'
    }

    File.write(c[:path], JSON.pretty_generate(c[:game]) + "\n") unless options[:dry_run]
    cp[options[:target]][c[:game]['id']] = true
    save_checkpoint(cp) if (i + 1) % 25 == 0

    done += 1
    if (i + 1) % 10 == 0 || i == 0
      total_elapsed = Time.now - start
      avg = total_elapsed / done
      remaining = candidates.size - (i + 1)
      eta_h = (remaining * avg / 3600.0).round(1)
      puts "  [#{i + 1}/#{candidates.size}] avg #{avg.round(1)}s/game, eta #{eta_h}h"
    end
  end

  save_checkpoint(cp)
  puts
  puts "translated: #{done}"
end

main if __FILE__ == $PROGRAM_NAME
