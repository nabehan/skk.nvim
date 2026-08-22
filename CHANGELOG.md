# Changelog

このプロジェクトの重要な変更はこのファイルに記録する。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.0.0/) を、バージョニングは
[Semantic Versioning](https://semver.org/lang/ja/) を参考にしている。

## [v0.1.0] - 2026-08-22

初回公開リリース。

### 主な機能

- ローマ字→かな/カタカナ変換、4モード切替（半角英数/ひらがな/カタカナ/全角英数）
- モード切替時のインジケーター表示（配色オプション対応）
- 辞書変換（`▽`/`▼`、送りあり/送りなし/abbrev）、候補選択ウィンドウ（配色・ページング対応）
- 単語登録UI（`vim.fn.input()` の再帰呼び出しによる、再帰的な単語登録に対応）
- Sticky-shift、個人辞書（学習）、複数辞書のマージ
- SKKサーバー（skkserv/yaskkserv2 等）連携
- 挿入モードのバッファに加え、コマンドラインモード（`:`/`/`）でも上記の大半に対応
- blink.cmp ネイティブソース統合（`▽`/`▼` 見出し語入力中の前方一致ライブ補完、実際の変換候補まで表示）
- キー設定の柔軟化（`enter_key` 系・`char_key_to_*` 系・`abbrev_key`）、`enable()`/`disable()`/`toggle()`/`is_enabled()` API
- `:checkhealth skk` によるセットアップ診断

### ロードマップ

- 未着手: 辞書パースのスレッドプール並列化（優先度低、長期的課題として保留）

[v0.1.0]: https://github.com/nabehan/skk.nvim/releases/tag/v0.1.0
