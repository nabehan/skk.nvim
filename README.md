# skk.nvim

Neovim 専用の SKK (Simple Kana to Kanji conversion program) 実装。
denops（Deno）や Vim 互換レイヤーに依存せず、Lua（LuaJIT）だけで完結させることを目標にする。

## なぜ作るか

[vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) は denops.vim 上で動作し、
補完エンジンの判定が Vimscript 側に `pum.vim` / `nvim-cmp` / ネイティブ補完の3種類しか
ハードコードされていない。[blink.cmp](https://github.com/Saghen/blink.cmp) のような
新しい補完エンジンとの組み合わせでは、この判定漏れが原因で `<CR>` 確定が機能しない等の
問題が発生する。

skk.nvim は Neovim の Lua API だけで完結させることで、こうした「相性問題」が
アーキテクチャ上そもそも起こらないようにする。

## 設計方針

- **Neovim専用。Vim互換は考えない**（`has('nvim')` 分岐や Vimscript フォールバックを書かない）
- **外部プロセスに依存しない**（denops 等の RPC を挟まない）。まずは Lua だけで実装し、
  実測でボトルネックが判明してから最小限の最適化を検討する
- 辞書ロードなど重い処理は起動をブロックしないよう非同期化する
- 補完候補の表示は特定の補完エンジンに結合させず、[blink.cmp](https://github.com/Saghen/blink.cmp)
  のネイティブソース API 経由で公開する（cmp.saghen.dev の Source インターフェース準拠）

## 参考にしたもの

- [uga-rosa/skk-learning.nvim](https://github.com/uga-rosa/skk-learning.nvim) — ローマ字→かな変換のステートマシン設計
- [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) — SKK の pre-edit (▽/▼) 表示・辞書仕様
- [vim-skk/ddskk](https://github.com/skk-dev/ddskk) — オリジナルの Emacs 実装
- [yuys13/skk-develop.nvim](https://github.com/yuys13/skk-develop.nvim) — SKK辞書ダウンローダー

## ロードマップ

- [ ] ローマ字→かな変換（状態機械）
- [ ] ▽/▼ pre-edit 表示（extmark）
- [ ] 辞書検索（送り仮名なし）
- [ ] 辞書検索（送り仮名あり）
- [ ] 個人辞書・学習
- [ ] blink.cmp ネイティブソース統合
- [ ] カタカナ・全角英数モード
- [ ] ドキュメント整備

## ライセンス

MIT
