# frozen_string_literal: true

require 'rexml/document'

# Read DAT-o-MATIC XML DATs and libretro/clrmamepro DATs into the same
# simple shape:
#   [{ name: "Game (Japan)", roms: [{ "size" => "...", "crc" => "..." }] }]
module DatReader
  module_function

  def read(path)
    text = File.read(path)
    if text.lstrip.start_with?('<')
      read_xml(text)
    else
      read_clrmamepro(text)
    end
  end

  def read_xml(text)
    doc = REXML::Document.new(text)
    games = []
    doc.root.elements.each('game') do |game_el|
      games << {
        name: game_el.attributes['name'],
        roms: xml_roms(game_el)
      }
    end
    games
  end

  def xml_roms(game_el)
    roms = []
    game_el.elements.each('rom') do |rom_el|
      roms << xml_attrs(rom_el)
    end
    roms
  end

  def xml_attrs(rom_el)
    attrs = {}
    %w[name size crc md5 sha1 sha256 serial status].each do |key|
      value = rom_el.attributes[key]
      attrs[key] = value unless value.nil? || value.empty?
    end
    attrs
  end

  def read_clrmamepro(text)
    games = []
    current = nil
    depth = 0

    text.each_line do |line|
      stripped = line.strip
      next if stripped.empty?

      if stripped == 'game ('
        current = { name: nil, roms: [] }
        depth = 1
        next
      end

      next unless current

      depth += stripped.count('(') - stripped.count(')')

      if stripped.start_with?('name ')
        current[:name] = parse_pairs(stripped)['name']
      elsif stripped.start_with?('rom ')
        current[:roms] << parse_pairs(stripped)
      end

      if depth <= 0
        games << current if current[:name]
        current = nil
      end
    end

    games
  end

  def parse_pairs(text)
    pairs = {}
    text.scan(/([A-Za-z0-9_]+)\s+(?:"((?:[^"\\]|\\.)*)"|([^\s()]+))/) do |key, quoted, bare|
      value = quoted || bare
      pairs[key] = value&.gsub('\"', '"')
    end
    pairs
  end
end
