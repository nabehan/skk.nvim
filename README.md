# skk.nvim

Neovim 専用（Vim 非対応）、denops/外部プロセスに依存しない、Lua だけで実装する SKK（日本語入力）プラグイン。

**現在ステータス: phase 1（ローマ字→かな変換エンジン + キャプチャ層の試作）。** まだ辞書変換（▽/▼、漢字変換）は実装していません。

## Design goals

- Neovim only. No Vim (vanilla) compatibility layer, no Vimscript.
- Pure Lua, no external process (no denops/Deno dependency).
- Key interception via `vim.on_key()`（挿入モードの `<expr>` マッピングを大量発行する方式は採らない）。
- Target: Neovim 0.10+（`vim.on_key()` の空文字列 return によるキー消費、`vim.schedule`, extmark 等を前提とする）

## なぜ作るか

既存の [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) は denops (Deno/TypeScript) 上で動作し、Vimscript 側 (`autoload/skkeleton.vim`) に「どの補完エンジンが動いているか」の判定がハードコードされている（`pum.vim` / `nvim-cmp` / ネイティブ補完の3種類のみ）。[blink.cmp](https://github.com/Saghen/blink.cmp) と組み合わせて使おうとした際、この判定に `blink.cmp` が該当せず、`eggLikeNewline` による `<CR>` 確定処理が発火しないなど、根本的な相性問題が繰り返し発生した。

これらは skkeleton のアーキテクチャ（denops + Vimscript ハイブリッド、固定の補完エンジン判定）に起因する問題であり、**Neovim 専用・Lua 完結の実装にすれば原理的に発生しない**という判断から、このプロジェクトを開始した。

## アーキテクチャ

```
lua/skk/
├── init.lua        -- エントリーポイント。setup() でキャプチャ層とキーマップを登録
├── capture.lua      -- vim.on_key() によるキー入力の横取り・バッファへの反映
├── context.lua      -- 入力状態（確定済み出力 / 未確定バッファ）を保持するオブジェクト
├── input.lua        -- ローマ字 → かな変換のステートマシン本体
└── kana_table.lua    -- ローマ字 → かな 変換テーブル（子音×母音から機械的に生成）
```

### 変換エンジン (`context.lua` + `input.lua` + `kana_table.lua`)

1キー入力ごとに `input.kanaInput(context, char)` を呼び出す。判定の優先順位:

1. 変換表に完全一致するか？ → 確定して終了
2. `"nn"` か？ → 「ん」を確定して終了
3. まだ何かの変換表エントリの prefix か？ → 入力待ち（何もしない）
4. 子音の連続（促音）か？ → 「っ」を確定し、2文字目から仕切り直す
5. `"n"` + (母音でも `y` でも `n` でもない文字) か？ → 「ん」を確定し、その文字から仕切り直す
6. どれにも当てはまらない → 先頭の1文字を捨てて仕切り直す（誤入力からの回復）

末尾の単独 `n`（例: `"nihon"` の末尾）は、次に「な行」が続くのか「ん」で確定するのか本質的に曖昧なため、次の入力が来るまで未確定のまま保留される。これは SKK 全般に共通する仕様であり、バグではない。

テストは `tests/input_spec.lua`（[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) の busted 互換ランナー）を参照。

### キャプチャ層 (`capture.lua`)

`vim.on_key()` は Neovim 公式ドキュメント（`:help vim.on_key()`）により、コールバックが空文字列 `""` を返すとそのキーを破棄できることを確認済み:

> If {fn} returns an empty string, {key} is discarded/ignored

これを利用し、挿入モードで半角英字 (`a-z`) が来るたびに元のキーを破棄し、変換エンジンに通した結果でバッファを書き換える。

未確定のローマ字断片（例: `"k"` だけ打った直後）は、専用の pre-edit 表示（skkeleton の `▽` に相当するもの）をまだ実装していないため、**そのまま普通の文字としてバッファに表示**しておき、変換が確定した瞬間にその文字数ぶんを消してかなに置き換える方式にしている。実装がシンプルで、何も表示されない不安がないという利点がある一方、本来の SKK の見た目とは異なる。

実際のバッファ書き換え (`nvim_buf_set_text`) は `vim.on_key()` のコールバック内で直接行わず、`vim.schedule()` で1ティック遅延させている。[blink.cmp との統合作業](https://github.com/nabehan/nvim-config-blink-skkeleton)で `E565: Not allowed to change text or change window` という textlock エラーを複数回踏んだ教訓から、同種の制約下にある可能性を考慮した予防的な対応。

## 既知の制限（phase 1 時点）

- 大文字入力（SKK の `▽` 開始トリガー）・辞書変換（`▼`、漢字変換）は未実装。現時点ではローマ字→かな変換のみ。
- 個人辞書・学習機能は未実装。
- コマンドラインモード・検索モードは未対応（挿入モードのみ）。
- 未確定バッファがある状態でカーソルを動かす、または `<BS>` を押すと、画面上のテキストと内部状態 (`context.buffer`) がずれる可能性がある（`<BS>` を明示的にハンドリングしていないため）。
- blink.cmp のネイティブソースとしての統合はまだ行っていない（[nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton) で得た知見はそのまま使える見込み）。

## 使い方（現状）

```lua
require("skk").setup({
  toggle_key = "<C-j>", -- デフォルト
})
```

挿入モードで `<C-j>` を押すと ON/OFF がトグルされる（`:SkkToggle` コマンドでも可）。ON の状態でローマ字を打つとかなに変換される。

## 開発時の動作確認

普段の Neovim 設定を汚さずに、このリポジトリ単体で動作確認できる最小 init（`skk_test_init.lua`）を同梱している。

```bash
nvim -u ./skk_test_init.lua
```

起動後、挿入モードで `<C-j>` → `ka`・`kka`・`kyou` などを打って変換されるか確認する。

## テスト

[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) の busted 互換ランナーで `tests/*_spec.lua` を実行する。`make test` で plenary.nvim を `.tests/site/pack/deps/start/` に自動取得してから実行するので、個人の Neovim 環境に plenary.nvim が入っているかどうかに関わらず動く。

```bash
make test
```

手動で実行したい場合、または既に別の場所に plenary.nvim がある場合は `PLENARY_DIR` 環境変数で指定できる。

```bash
PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim \
  nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

## ロードマップ

1. ~~ローマ字 → かな変換エンジン~~ ✅
2. ~~`vim.on_key()` によるキー横取り~~ ✅（MVP）
3. `▽`/`▼` の pre-edit 表示を extmark ベースに置き換える
4. 辞書検索（`SKK-JISYO.L` 読み込み、送り仮名なしから）
5. 個人辞書・学習（頻度に応じた並び替え）
6. blink.cmp ネイティブソースとしての統合
7. 送り仮名処理、周辺 UI（モードインジケーター等）

## 参考にしたプロジェクト

- [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton)
- [uga-rosa/skk-learning.nvim](https://github.com/uga-rosa/skk-learning.nvim) — Lua での SKK 実装入門
- [yuys13/skk-develop.nvim](https://github.com/yuys13/skk-develop.nvim) — SKK辞書ダウンローダー
