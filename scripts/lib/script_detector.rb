# frozen_string_literal: true

# 文字列から ISO 15924 スクリプトコードを判定する。
# retronian-gamedb の独自価値の核。
#
# 返り値の ISO 15924 コード:
#   Jpan - 日本語（漢字を含む混在）
#   Hira - ひらがなのみ
#   Kana - カタカナのみ（ひらがな・漢字を含まない）
#   Hang - 한글（ハングル）
#   Hans - 簡体字（判別困難なので実運用では手動指定推奨）
#   Hant - 繁体字
#   Latn - ラテン文字
#   Cyrl - キリル文字
#   Zyyy - 判定不能・記号のみ
module ScriptDetector
  module_function

  # Unicode プロパティ正規表現で文字種を判定
  def detect(text)
    return 'Zyyy' if text.nil? || text.strip.empty?

    has_hira  = text.match?(/\p{Hiragana}/)
    has_kata  = text.match?(/[\p{Katakana}ー]/)
    has_han   = text.match?(/\p{Han}/)
    has_hang  = text.match?(/\p{Hangul}/)
    has_latin = text.match?(/\p{Latin}/)
    has_cyrl  = text.match?(/\p{Cyrillic}/)

    # 日本語系（ひらがな・カタカナ・漢字のいずれかを含む）
    if has_hira || has_kata || has_han
      # 漢字を含むなら混在扱い（Jpan）
      return 'Jpan' if has_han
      # ひらがなとカタカナが両方あるなら Jpan
      return 'Jpan' if has_hira && has_kata
      # ひらがなのみ
      return 'Hira' if has_hira
      # カタカナのみ
      return 'Kana' if has_kata
    end

    return 'Hang' if has_hang
    return 'Latn' if has_latin
    return 'Cyrl' if has_cyrl

    'Zyyy'
  end
end

# 直接実行時は簡易テスト
if __FILE__ == $PROGRAM_NAME
  samples = {
    '星のカービィ'             => 'Jpan',
    'ほしのカービィ'           => 'Hira',
    'スーパーマリオブラザーズ' => 'Kana',
    'ファイナルファンタジーVI' => 'Kana',  # VI はラテン文字だがカタカナ主体
    'Kirby\'s Dream Land'      => 'Latn',
    'Hoshi no Kirby'           => 'Latn',
    '별의 커비'                => 'Hang',
    ''                         => 'Zyyy'
  }

  puts "=== ScriptDetector テスト ==="
  samples.each do |text, _expected|
    result = ScriptDetector.detect(text)
    puts "  #{result.ljust(5)} | #{text}"
  end
end
