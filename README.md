# skk.nvim

Neovim 専用（Vim 非対応）、denops/外部プロセスに依存しない、Lua だけで実装する SKK（日本語入力）プラグイン。

**現在ステータス: phase 2（5モード切替対応）。** まだ辞書変換（▽/▼、漢字変換）は実装していません。

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
├── capture.lua      -- vim.on_key() によるキー入力の横取り・モードに応じた変換の振り分け
├── mode.lua          -- 5モードの状態遷移ロジック（vim.* 非依存、単体テスト可能）
├── context.lua      -- 入力状態（確定済み出力 / 未確定バッファ / 現在モード）を保持するオブジェクト
├── input.lua        -- ローマ字 → かな変換のステートマシン本体
├── kana_table.lua    -- ローマ字 → ひらがな 変換テーブル（子音×母音から機械的に生成）
└── kana_util.lua     -- ひらがな⇔カタカナ⇔全角英数の相互変換
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

促音「っ」は子音の連続（`kka` → `っか`）のほか、`kana_table.lua` に `M["xtu"] = "っ"` を明示的に定義しているので `xtu` と打っても単独で「っ」になる（多くの日本語IMEにある慣習的な入力方法）。

`z` + 記号で全角記号を入力できる（同じく多くの日本語IMEにある慣習）: `z(` → `（`、`z)` → `）`、`z`+スペース → `　`（全角スペース）。これらを `capture.lua` の `EXTRA_TARGET_CHARS` に追加するにあたり、`(`・`)`・スペース単独では素通し（半角のまま）になるよう `kana_table.lua` に恒等変換（`M["("] = "("` 等）も用意している（そうしないと、変換表にもprefixにも該当しない単独の記号として誤って破棄されてしまうため）。

テストは `tests/input_spec.lua`（[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) の busted 互換ランナー）を参照。

### キャプチャ層 (`capture.lua`)

`vim.on_key()` は Neovim 公式ドキュメント（`:help vim.on_key()`）により、コールバックが空文字列 `""` を返すとそのキーを破棄できることを確認済み:

> If {fn} returns an empty string, {key} is discarded/ignored

これを利用し、挿入モードで半角英字 (`a-z`) が来るたびに元のキーを破棄し、変換エンジンに通した結果でバッファを書き換える。

未確定のローマ字断片（例: `"k"` だけ打った直後）は、専用の pre-edit 表示（skkeleton の `▽` に相当するもの）をまだ実装していないため、**そのまま普通の文字としてバッファに表示**しておき、変換が確定した瞬間にその文字数ぶんを消してかなに置き換える方式にしている。実装がシンプルで、何も表示されない不安がないという利点がある一方、本来の SKK の見た目とは異なる。

実際のバッファ書き換え (`nvim_buf_set_text`) は `vim.on_key()` のコールバック内で直接行わず、`vim.schedule()` で1ティック遅延させている。[blink.cmp との統合作業](https://github.com/nabehan/nvim-config-blink-skkeleton)で `E565: Not allowed to change text or change window` という textlock エラーを複数回踏んだ教訓から、同種の制約下にある可能性を考慮した予防的な対応。

### モード (`mode.lua` + `kana_util.lua`)

本家 SKK は5モード（半角英数/ひらがな/カタカナ/全角英数/半角カナ）だが、半角カナは実装しない方針としたため、このプラグインでは4モードを実装している。

| モード | 内容 |
| --- | --- |
| `ascii`（半角英数） | SKK が事実上 OFF の状態。キー入力は完全パススルー |
| `hira`（ひらがな） | 通常のローマ字入力 |
| `kata`（カタカナ） | ローマ字入力の結果をカタカナで表示 |
| `zenei`（全角英数） | 印字可能な半角ASCII文字をすべて全角に変換する（`q` を打っても `ｑ`。モード切替キーとしては扱わない） |

**モード遷移表（`lua/skk/mode.lua`）:**

```
半角英数 --<C-j>--> ひらがな
全角英数 --<C-j>--> ひらがな
ひらがな --l-->     半角英数
ひらがな --q-->     カタカナ
ひらがな --L-->     全角英数
カタカナ --l-->     半角英数
カタカナ --q-->     ひらがな
カタカナ --L-->     全角英数
```

`l`/`q`/`L` は印字可能な文字なので `capture.lua` の `vim.on_key()` コールバック内で、**未確定のローマ字バッファが空のときに限り**モード切替キーとして特別扱いする（バッファが空でなければ通常のローマ字入力として処理する）。`<C-j>` は制御キーなので `init.lua` が通常の `vim.keymap.set` 経由で `capture.transition()` を呼ぶ。

**半角カナモードについて:** 当初は本家 SKK にならって実装する計画だったが、実際に試したところ**半角カナを挿入するとターミナルエミュレーターの動作が不安定になる事例が確認された**ため、実装しない方針に変更した（`<C-q>` キーも現在は未使用）。

**カタカナへの変換方式:** `kana_table.lua` をカタカナ版として複製するのではなく、`kana_util.lua` の変換関数を「ひらがな確定後の後処理」として適用する方式にしている。

- ひらがな→カタカナ: ひらがな (`U+3041`–`U+3096`) とカタカナ (`U+30A1`–`U+30F6`) は小書き文字を含め例外なく `+0x60` のオフセットで対応しているため、コードポイント演算1つで変換できる。
- 半角英数→全角英数: 半角ASCII (`0x21`–`0x7E`) は `+0xFEE0` で全角形 (`U+FF01`–`U+FF5E`) に対応する。半角スペース (`0x20`) だけ全角スペース (`U+3000`) への特別扱いが必要（`+0xFEE0` すると未割り当ての `U+FF00` になってしまうため）。

この方式なら `kana_table.lua` は1つのまま維持でき、表の二重管理・ズレのリスクがない（実際、今回小文字かな `xa`/`xya` 等を追加した際もカタカナ側は自動的に追随した）。

**なぜ自前で UTF-8 デコード/エンコードを書いているか:** Lua 5.3+ の標準 `utf8` ライブラリは LuaJIT（Neovim の既定の Lua 実装）には含まれていない。この開発環境（`lua5.4`）で動くコードでも、実際の Neovim (LuaJIT) では `utf8.codes` 等が存在せず壊れる可能性があるため、`kana_util.lua` はバイト列から直接コードポイントを読み書きする最小限のデコーダ/エンコーダを自前で実装している。

## 既知の制限（phase 2 時点）

- 大文字入力（SKK の `▽` 開始トリガー）・辞書変換（`▼`、漢字変換）は未実装。今のところローマ字→かな/カタカナ変換とモード切替のみ。
- 個人辞書・学習機能は未実装。
- コマンドラインモード・検索モードは未対応（挿入モードのみ）。
- ~~未確定バッファがある状態で `<BS>`/`<Delete>` を押すと、画面上のテキストと内部状態 (`context.buffer`) がずれる~~ → **修正済み。** 個別にキーごとハンドリングするのではなく、`is_target_key` に該当しない（＝ローマ字入力の続きとして認識できない）キーが来た時点で `context.buffer` を無条件にリセットする、という汎用的な対処にした。放置すると、次のキー入力時に「本来消すべきでないバイト数」を削除してしまい、既存の確定済みかな（マルチバイト文字）の末尾バイトだけを削って不正なバイト列に破壊してしまう実害のあるバグだった（`<BS>`・`<Delete>` の両方で実際に確認・修正済み）。この汎用リセットのおかげで、今後遭遇しうる未知のキーでも同種の破壊は起こらない。
- ただし `<Left>`/`<Right>` などのカーソル移動キーやマウスクリックは、未確定バッファをリセットするだけで済む上記の対処では**表示上の不整合**（例: 未確定ローマ字がそのまま残る）が起こりうる。破壊されるわけではないが、対処は今後の課題。
- blink.cmp のネイティブソースとしての統合はまだ行っていない（[nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton) で得た知見はそのまま使える見込み）。

## 使い方（現状）

```lua
require("skk").setup({
  enter_key = "<C-j>",   -- デフォルト。半角英数/全角英数 -> ひらがな
})
```

初期モードは `半角英数`（SKK 実質 OFF）。挿入モードで `<C-j>` を押すとひらがなモードに入る。以降は前述のモード遷移表（`l`/`q`/`L`）でモードを切り替えながら入力する。`:SkkMode` コマンドで現在のモードを確認できる。

## 開発時の動作確認

普段の Neovim 設定を汚さずに、このリポジトリ単体で動作確認できる最小 init（`skk_test_init.lua`）を同梱している。

```bash
nvim -u ./skk_test_init.lua
```

起動後、挿入モードで `<C-j>` → `ka`・`kka`・`kyou`・`xtu` などを打って変換されるか確認する。モード切替も試す: `q`（ひらがな⇔カタカナ）、`l`（→半角英数）、`L`（→全角英数）。`:SkkMode` で現在のモードを確認できる。

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
3. ~~4モード（半角英数/ひらがな/カタカナ/全角英数）の相互切替~~ ✅
4. `▽`/`▼` の pre-edit 表示を extmark ベースに置き換える
5. 辞書検索（`SKK-JISYO.L` 読み込み、送り仮名なしから）
6. 個人辞書・学習（頻度に応じた並び替え）
7. blink.cmp ネイティブソースとしての統合
8. 送り仮名処理、周辺 UI（モードインジケーター等）

## 参考にしたプロジェクト

- [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton)
- [uga-rosa/skk-learning.nvim](https://github.com/uga-rosa/skk-learning.nvim) — Lua での SKK 実装入門
- [yuys13/skk-develop.nvim](https://github.com/yuys13/skk-develop.nvim) — SKK辞書ダウンローダー
