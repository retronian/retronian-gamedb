# Native Game DB

レトロゲームのネイティブスクリプト（ひらがな・カタカナ・漢字・ハングル・漢字等、非ラテン文字の本来の表記）対応ゲームデータベース。

## なぜ作るのか

既存の主要レトロゲームDB（ScreenScraper.fr / TheGamesDB / IGDB / MobyGames 等）は、日本語リージョンを指定してもローマ字表記しか返さない、あるいは非構造化フィールドに散在しているという構造的問題がある。

Native Game DB は以下を提供する：

- **構造化された多言語・多スクリプトのタイトル表記**
- **ひらがな / カタカナ / 漢字混在 の区別**（ISO 15924 による）
- **完全サーバーレス配信**（GitHub Pages で JSON を静的配信）
- **GitHub ベースのコミュニティ投稿**（Issue → 自動 PR）

## 独自価値

どの既存 DB にも無いのが、タイトルの **`script` カラム**（ISO 15924）です。

| 表記 | `lang` | `script` | 意味 |
|---|---|---|---|
| 星のカービィ | `ja` | `Jpan` | 漢字混在の日本語 |
| ほしのカービィ | `ja` | `Hira` | ひらがなのみ |
| スーパーマリオブラザーズ | `ja` | `Kana` | カタカナのみ |
| Hoshi no Kirby | `ja` | `Latn` | ローマ字転写 |
| Kirby's Dream Land | `en` | `Latn` | 英語 |

言語タグ `ja` だけでは表現できない「ひらがなのみ」「カタカナのみ」の区別が可能です。FC 初期タイトルはカタカナのみのものが多く、この区別はレトロゲームメタデータで実質的な意味を持ちます。

## データ構造

1 ゲーム = 1 JSON ファイル（`data/games/{platform}/{id}.json`）。

```json
{
  "id": "hoshi-no-kirby",
  "platform": "gb",
  "category": "main_game",
  "first_release_date": "1992-04-27",
  "titles": [
    { "text": "星のカービィ", "lang": "ja", "script": "Jpan", "region": "jp", "form": "boxart", "source": "wikidata", "verified": true },
    { "text": "Kirby's Dream Land", "lang": "en", "script": "Latn", "region": "us", "form": "official", "source": "wikidata", "verified": true }
  ],
  "developers": ["hal-laboratory"],
  "publishers": ["nintendo"],
  "genres": ["platformer"],
  "external_ids": {
    "wikidata": "Q1064715",
    "igdb": 1083
  }
}
```

詳しくは [`schema/game.schema.json`](schema/game.schema.json) を参照。

### `titles[]` の 7 軸

- `text`: タイトル文字列
- `lang`: ISO 639-1 言語コード (`ja` / `en` / `ko` / `zh` ...)
- `script`: **ISO 15924 スクリプトコード**（`Jpan` / `Hira` / `Kana` / `Hans` / `Hant` / `Latn` ...）
- `region`: ISO 3166-1 国コード (`jp` / `us` / `eu` / `kr` ...)
- `form`: `official` / `boxart` / `ingame_logo` / `manual` / `romaji_transliteration` / `alternate`
- `source`: `wikidata` / `igdb` / `mobygames` / `screenscraper` / `no_intro` / `community` / `manual`
- `verified`: 一次資料（タイトル画面・当時のパッケージ）確認済みか

## 対応プラットフォーム（初期）

FC / SFC / GB / GBC / GBA / MD / PCE / N64 / NDS

## 設計思想

主要ゲーム DB の良いところを取り込み、欠点を避けた。

- **Wikidata 流**: 全値に言語タグを付与
- **ScreenScraper 流**: リージョン軸と言語軸の分離
- **IGDB 流**: リリース日を (region × platform) で独立させる
- **MobyGames の反面教師**: フリーテキストラベルを使わない（構造化 enum）
- **TheGamesDB の反面教師**: 裸の文字列配列を使わない
- **Native Game DB 独自**: `script` カラム（ISO 15924）

## ロードマップ

- **Phase 0**: スキーマ設計・ディレクトリ構造 ← ★ 現在ここ
- **Phase 1**: Wikidata SPARQL スクレイパー（Ruby）で初期データ投入
- **Phase 2**: IGDB `game_localizations` で補完
- **Phase 3**: GitHub Pages で静的配信
- **Phase 4**: GitHub Issue → 自動 PR によるコミュニティ投稿
- **Phase 5**: [retronian/romu](https://github.com/retronian/romu) との統合

## 関連プロジェクト

- [retronian/romu](https://github.com/retronian/romu) — ROM collection manager（データ消費者）
- [komagata/gamelist-ja](https://github.com/komagata/gamelist-ja) — EmulationStation 向け日本語 gamelist 生成ツール（前身）
- [komagata/skyscraper-ja](https://github.com/komagata/skyscraper-ja) — Skyscraper キャッシュへの日本語インポート（前身）
- [retronian/OneOS](https://github.com/retronian/OneOS) — MinUI フォークの日本語対応 CFW（表示側）

## コントリビューション

準備中（Phase 4 で GitHub Issue テンプレートを用意予定）。

## ライセンス

未定（CC0 または MIT 予定）。
