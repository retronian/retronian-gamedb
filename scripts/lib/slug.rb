# frozen_string_literal: true

# Shared slug helpers used by all merge/fetch scripts.
#
# `slugify` gives the canonical slug that retronian-gamedb files use on
# disk: lowercase ASCII, hyphen-separated, Latin letters and digits only.
#
# `aliases_for` returns a list of variants to try when matching external
# data against retronian-gamedb slugs. It expands common differences such
# as Roman ↔ Arabic numerals ("ii" ↔ "2") and "and" ↔ "&" so that
# "double-dragon-ii-the-revenge" and "double-dragon-2-the-revenge"
# collide.
module Slug
  module_function

  def slugify(text)
    return nil if text.nil? || text.empty?
    ascii = text.unicode_normalize(:nfkd)
                .encode('ASCII', invalid: :replace, undef: :replace, replace: '')
    slug = ascii.downcase
                .gsub('&', ' and ')
                .gsub(/[^a-z0-9\s-]+/, ' ')
                .strip
                .gsub(/\s+/, '-')
                .gsub(/-+/, '-')
                .gsub(/^-+|-+$/, '')
    slug.empty? ? nil : slug
  end

  # Strip trailing " (Japan)", " (Rev A)", etc. before slugifying.
  def strip_no_intro_suffixes(name)
    name.to_s.gsub(/\s*\([^)]*\)\s*/, ' ').strip
  end

  # Roman numeral -> Arabic numeral substitution applied word-by-word.
  # We only rewrite multi-letter Roman numerals (ii/iii/iv/...) because
  # a single "i" or "v" matches too many real English words.
  ROMAN_MAP = {
    'ii'    => '2',
    'iii'   => '3',
    'iv'    => '4',
    'vi'    => '6',
    'vii'   => '7',
    'viii'  => '8',
    'ix'    => '9',
    'xi'    => '11',
    'xii'   => '12',
    'xiii'  => '13',
    'xiv'   => '14',
    'xv'    => '15',
    'xvi'   => '16',
    'xvii'  => '17',
    'xviii' => '18'
  }.freeze

  def normalize_numerals(slug)
    return slug if slug.nil?
    parts = slug.split('-')
    out = parts.map { |p| ROMAN_MAP[p] || p }
    out.join('-')
  end

  # Expand common short-hand differences:
  #   - "vol-1" vs "volume-1"
  #   - "no-1" vs "1"
  #   - remove trailing "the" articles
  def canonical(slug)
    return nil if slug.nil?
    s = normalize_numerals(slug)
    s = s.gsub(/\bvolume\b/, 'vol')
         .gsub(/\bthe\b/, '')
         .gsub(/-+/, '-')
         .gsub(/^-+|-+$/, '')
    s.empty? ? nil : s
  end

  # Return every slug variant we want to try for this entity.
  def aliases_for(text)
    return [] if text.nil? || text.empty?
    s = slugify(text)
    return [] if s.nil?
    variants = [s, normalize_numerals(s), canonical(s)]
    variants.uniq.compact
  end
end
