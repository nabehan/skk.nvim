# skk.nvim

Neovim 専用（Vim 非対応）、denops/外部プロセスに依存しない、Lua だけで実装する SKK（日本語入力）プラグイン。

**現在ステータス:** ローマ字→かな/カタカナ変換・4モード切替（切替時はカーソル位置にモードインジケーターを表示）に加えて、辞書変換（`▽`/`▼`、送りあり/送りなし/abbrev）・候補選択ウィンドウ（`<C-n>`/`<C-p>`フォーカス移動対応）・単語登録（`vim.fn.input()`の再帰呼び出しによる、再帰的な単語登録に対応したUI）・Sticky-shift・個人辞書（学習）・複数辞書のマージ・SKKサーバー連携に対応。大きな辞書ファイルは非同期・遅延パースで読み込む。挿入モードのバッファに加え、**コマンドラインモード**（`:`/`/`）でもローマ字→かな変換・4モード切替・モードインジケーター・辞書変換（`▽`/`▼`、候補選択ウィンドウ）・単語登録まで一通り対応済み。内蔵ターミナルは対応しない方針（後述）。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim) の最小構成例（辞書なしでもロード・モード切替までは試せる。辞書変換には別途辞書ファイルの読み込みが必要、後述の「使い方」参照）:

```lua
{
  "nabehan/skk.nvim",
  -- version = "*", -- タグ（例: v0.1.0）が付いたリリースだけを使いたい場合はコメントを外す。
  --                   省略時は main ブランチの最新（開発中の変更が含まれうる）を追跡する。
  config = function()
    require("skk").setup({
      -- お好みで。省略時のデフォルトについては後述の「使い方」参照。
    })

    -- 辞書変換（▽/▼）を使うには、setup() とは別に辞書ファイルを読み込む必要がある。
    -- SKK-JISYO.L 等は https://github.com/skk-dev/dict から入手できる。
    require("skk.dict").load_dictionary_async(
      "/usr/share/skk/SKK-JISYO.L",
      "euc-jp"
    )
  end,
}
```

[blink.cmp](https://github.com/Saghen/blink.cmp) や SKKサーバー（skkserv/yaskkserv2 等）と組み合わせる場合の設定例は、後述の「使い方」および「blink.cmp ネイティブソース統合」を参照。実際に動く最小構成は [nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox) の `init.lua` も参考になる。

要件: Neovim 0.10 以上（`vim.on_key()` の空文字列 return によるキー消費、`vim.schedule`、extmark 等を使用）。denops や他の外部プロセスへの依存は無い。

## モード (`mode.lua` + `kana_util.lua`)

本家 SKK は5モード（半角英数/ひらがな/カタカナ/全角英数/半角カナ）だが、半角カナは実装しない方針としたため、このプラグインでは4モードを実装している。

| モード              | 内容                                                                                                 |
| ------------------- | ---------------------------------------------------------------------------------------------------- |
| `ascii`（半角英数） | SKK が事実上 OFF の状態。キー入力は完全パススルー                                                    |
| `hira`（ひらがな）  | 通常のローマ字入力                                                                                   |
| `kata`（カタカナ）  | ローマ字入力の結果をカタカナで表示                                                                   |
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

**半角カナモードについて:** 当初は本家 SKK にならって実装する計画だったが、実際に試したところ**半角カナを挿入するとターミナルエミュレーターの動作が不安定になる事例が確認された**ため、実装しない方針に変更した。`<C-q>` キーはモード切替としては使わないが、abbrev モード中に限り「全角変換して確定」の意味で使う（後述の「変換（`▽`/`▼`、henkan）」参照）。

**カタカナへの変換方式:** `kana_table.lua` をカタカナ版として複製するのではなく、`kana_util.lua` の変換関数を「ひらがな確定後の後処理」として適用する方式にしている。

- ひらがな→カタカナ: ひらがな (`U+3041`–`U+3096`) とカタカナ (`U+30A1`–`U+30F6`) は小書き文字を含め例外なく `+0x60` のオフセットで対応しているため、コードポイント演算1つで変換できる。
- 半角英数→全角英数: 半角ASCII (`0x21`–`0x7E`) は `+0xFEE0` で全角形 (`U+FF01`–`U+FF5E`) に対応する。半角スペース (`0x20`) だけ全角スペース (`U+3000`) への特別扱いが必要（`+0xFEE0` すると未割り当ての `U+FF00` になってしまうため）。

この方式なら `kana_table.lua` は1つのまま維持でき、表の二重管理・ズレのリスクがない（実際、今回小文字かな `xa`/`xya` 等を追加した際もカタカナ側は自動的に追随した）。

**なぜ自前で UTF-8 デコード/エンコードを書いているか:** Lua 5.3+ の標準 `utf8` ライブラリは LuaJIT（Neovim の既定の Lua 実装）には含まれていない。この開発環境（`lua5.4`）で動くコードでも、実際の Neovim (LuaJIT) では `utf8.codes` 等が存在せず壊れる可能性があるため、`kana_util.lua` はバイト列から直接コードポイントを読み書きする最小限のデコーダ/エンコーダを自前で実装している。

## 使い方

```lua
require("skk").setup({
  enter_key = "<C-j>", -- 半角英数/全角英数 -> ひらがな。henkan 中は <CR> 相当（確定）。省略時 "<C-j>"
  -- バッファとコマンドラインで別のキーにしたい場合（他プラグインとの競合回避等）は
  -- enter_key の代わりに、または enter_key と併用して次の2つを指定する：
  -- buffer_enter_key = "<C-j>", cmdline_enter_key = "<C-j>",

  -- l/q/L・abbrev開始（"/"）の物理キー。他プラグイン（skkeleton等）との共存や
  -- キーボード配列の都合で変えたい場合に指定する。省略時は現状通り。
  -- char_key_to_ascii = "l",         -- ひらがな/カタカナ -> 半角英数
  -- char_key_to_kata_or_hira = "q",  -- ひらがな<->カタカナの相互遷移
  -- char_key_to_zenei = "L",         -- ひらがな/カタカナ -> 全角英数
  -- abbrev_key = "/",                -- abbrevモード開始

  sticky_shift_enabled = true, -- Sticky-shift の有効/無効。省略時 true
  sticky_shift_key = ";",      -- Sticky-shift のトリガーキー。省略時 ";"（sticky_shift_enabled=false なら無視される）

  egg_like_newline = true, -- true: ▼状態での<CR>は確定のみ（改行しない、skk.nvimのデフォルト）
                            -- false: 確定に加えて改行も挿入する（SKK本来の動作）

  candidate_window = {
    border = "rounded",   -- "rounded"/"single"/"double"/"none"/自前の文字配列。省略時 "rounded"
    annotation = true,    -- 候補一覧に辞書の注釈（;注釈）を表示するか。省略時 true
    page_indicator = true, -- 最下行に "現在ページ/全ページ数"（例: "2/3"）を表示するか。省略時 true
    threshold = 2, -- <SPC>を何回打鍵した時点で候補一覧ウィンドウを表示するか。省略時 2

    -- 配色（すべて省略時はカラースキームの NormalFloat/FloatBorder のまま、現状と同じ見た目）
    -- fg = "#d8dee9", bg = "#2e3440",   -- 非選択の候補行
    -- border_fg = "#88c0d0",            -- 枠線
    -- alt_fg = "#d8dee9", alt_bg = "#1b4252", -- 1行おきの縞模様（省略時は縞なし）
  },

  -- ▽/▼のインライン表示の配色（省略時はComment/IncSearchのまま、現状と同じ）。
  -- candidate_fg/bgは候補ウィンドウの選択行のハイライトにも連動する。
  -- midashi_fg = "#81a1c1", midashi_bg = nil,
  -- candidate_fg = "#ebcb8b", candidate_bg = "#4c566a",

  -- モード切替時にカーソル位置へ一瞬表示するインジケーター（ひら/カタ/latn/ＬＡ）の
  -- 配色（省略時はNormalFloatのまま、現状と同じ）。
  -- indicator_fg = "#2e3440", indicator_bg = "#ff9e64",

  -- 候補一覧ウィンドウ表示中の <C-n>/<C-p> によるフォーカス移動。blink.cmp 等が
  -- 挿入モードに <C-n>/<C-p> の実キーマップを張っている環境向けの対策（詳細は
  -- 後述の「blink.cmp ネイティブソース統合」参照）。setup() を呼ぶ前に、
  -- blink.cmp 等の setup() を済ませておく必要がある。デフォルト有効。
  -- candidate_navigation = { enabled = true, next_key = "<C-n>", prev_key = "<C-p>" },

  user_dictionary = "~/.local/share/skk/SKK-JISYO.user", -- 個人辞書（学習）ファイルのパス。省略時この値
})
```

各オプションの詳細（デフォルト値・組み合わせ時の注意点）は `lua/skk/init.lua` の `SkkSetupOpts` の docstring、または `:help skk.nvim-options` を参照。

初期モードは `半角英数`（SKK 実質 OFF）。挿入モードで `<C-j>` を押すとひらがなモードに入る。以降は前述のモード遷移表（`l`/`q`/`L`）でモードを切り替えながら入力する。`:SkkMode` コマンドで現在のモードを確認できる。

他プラグインとの連携用に、`require("skk").enable()`/`disable()`/`toggle()`/`is_enabled()`（skkeleton の `<Plug>(skkeleton-enable)` 等相当）と、対応する `:SkkEnable`/`:SkkDisable`/`:SkkToggle` コマンドも用意している。`enable()` はひらがなモードへ、`disable()` は半角英数モード（henkan進行中なら先にキャンセル）へ遷移する。

`:checkhealth skk` で、Neovimのバージョン要件・`setup()` の実行状況・blink.cmp（任意）の検出・ローカル辞書の読み込み結果・skkservの疎通を診断できる。

辞書を使う（`▽`/`▼` 変換）には、`setup()` とは別に辞書を読み込んで登録する必要がある。SKK-JISYO.L や .LL のような大きな辞書ファイルは `load_dictionary_async()`（非同期・遅延パース）を推奨する:

```lua
local dict = require("skk.dict")

dict.load_dictionary_async("/path/to/SKK-JISYO.L", "euc-jp", function(ok, err)
  if not ok then
    vim.notify("skk.nvim: 辞書の読み込みに失敗しました: " .. tostring(err), vim.log.levels.WARN)
  end
end)
```

小さい辞書や同期読み込みで十分な場合は `file_source.load()` + `dict.set_dict()` でも良い:

```lua
local dict = require("skk.dict")
local file_source = require("skk.dict.file_source")

local parsed, err = file_source.load("/path/to/SKK-JISYO.L", "euc-jp") -- 文字コードは辞書ファイルに合わせる
if parsed then
  dict.set_dict(parsed)
end
```

複数の辞書ファイルや SKKサーバーを併用する場合（`skkeleton` の `globalDictionaries`/`skk_server` に相当する構成）:

```lua
require("skk").setup({
  skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" },
  -- ...他のオプション
})

local dict = require("skk.dict")
dict.load_dictionary_async("/usr/share/skk/SKK-JISYO.L", "euc-jp") -- メイン辞書
dict.add_dictionary_async("/usr/local/share/skk/SKK-JISYO.edict2", "utf-8")
dict.add_dictionary_async("/usr/local/share/skk/SKK-JISYO.emoji", "utf-8")
```

同じ構成は `setup()` の `dictionaries` オプションだけでも書ける（`dict.add_dictionary_async()` を登録順に呼ぶのを `setup()` が代行するだけなので、優先順位や非同期・遅延パースといった挙動は上の書き方と全く同じ）。`setup()` 呼び出しが一箇所にまとまるので、`config = function() ... end` 内を短く保ちたい場合に使うとよい:

```lua
require("skk").setup({
  skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" },
  dictionaries = {
    { path = "/usr/share/skk/SKK-JISYO.L", encoding = "euc-jp" }, -- メイン辞書
    { path = "/usr/local/share/skk/SKK-JISYO.edict2", encoding = "utf-8" },
    { path = "/usr/local/share/skk/SKK-JISYO.emoji", encoding = "utf-8" },
  },
  on_dictionary_loaded = function(path, ok, err) -- 省略可。読み込み完了のたびに呼ばれる
    if not ok then
      vim.notify("skk.nvim: " .. path .. " の読み込みに失敗: " .. tostring(err), vim.log.levels.WARN)
    end
  end,
  -- ...他のオプション
})
```

`dictionaries` は常に `add_dictionary_async()`（非同期・遅延パース、複数辞書の追加登録）を使う。1件目からメイン辞書として `load_dictionary_async()` を使いたい場合（＝2件目以降を追加した時点で1件目を丸ごと置き換えたい場合）は、引き続き上の `dict.load_dictionary_async()` を直接呼ぶ書き方を使う。

`skk_test_init.lua` は環境変数 `SKK_SKKSERV_HOST`/`SKK_JISYO_PATHS`（`:` 区切り）/`SKK_JISYO_PATHS_ENCODING` で、この構成をそのまま試せるようにしてある（ファイル冒頭のコメント参照）。

blink.cmp と組み合わせる場合は、`require("skk").setup({ blink = {...} })` で `blink_source.lua` 側の設定（`max_items`・`skip_skkserv`・`skkserv_candidates`・`skkserv_candidate_limit`、詳細は後述の「blink.cmp ネイティブソース統合」参照）を渡した上で、blink.cmp 自体の `sources.providers` にソースとして登録する（登録自体はこのプラグインの外、ユーザー設定側の責務）。`▽`/`▼` に合わせたメニューの表示切替は `SkkHenkanChanged` autocmd を使う（詳細は後述の「blink.cmp ネイティブソース統合」参照）:

```lua
require("skk").setup({
  blink = {
    max_items = 50,               -- 前方一致で取得する読みの上限件数。省略時50
    skip_skkserv = false,         -- "4"（読み一覧取得）にSKKサーバーを含めるか。省略時false
    skkserv_candidates = true,    -- "1"（実際の変換候補取得）にSKKサーバーを含めるか。省略時true
    skkserv_candidate_limit = 20, -- SKKサーバーへ"1"を投げる読みの上限件数。省略時20
  },
  -- ...他のオプション
})

require("blink-cmp").setup({
  sources = {
    default = { "skk", "lsp", "path", "snippets", "buffer" },
    providers = {
      skk = {
        name = "skk",
        module = "skk.blink_source",
        enabled = function()
          -- "midashi"（▽、通常のかな漢字変換）だけでなく "abbrev"
          -- （▽、"/" で始める英字そのままの見出し）でも有効にする。
          -- 詳細は下記「さらに注意4」参照。
          local phase = require("skk.henkan.state").get_phase()
          return phase == "midashi" or phase == "abbrev"
        end,
      },
    },
  },
})

-- ▽/▼ の表示に合わせて blink.cmp のメニューを show()/hide() する。
-- ▼（候補選択）中は skk.nvim 自身の候補選択ウィンドウが出るため hide() し、
-- blink.cmp のメニューと競合しないようにする。
--
-- 【重要】show() には必ず providers = { "skk" } を明示すること。
-- blink.cmp の show() は「メニューが既に開いていて providers を
-- 指定しない場合は何もしない」というガードを持つ。skk.nvim の ▽/▼ は
-- extmark（仮想テキスト）表示で実バッファは変化しないため、blink.cmp
-- 自身の「実テキストの変更を検知して自動的に再要求する」通常の仕組みは
-- 働かない。providers を省略すると、▽に入った直後（読みが空文字）の
-- 1回目でメニューが開いた後、読みが伸びても2回目以降の show() が
-- 無視され、候補リストが更新されないまま止まってしまう。
vim.api.nvim_create_autocmd("User", {
  pattern = "SkkHenkanChanged",
  callback = function(ev)
    local phase = ev.data and ev.data.phase
    if phase == "midashi" or phase == "abbrev" then
      vim.schedule(function()
        require("blink.cmp").show({ providers = { "skk" } })
      end)
    else
      require("blink.cmp").hide()
    end
  end,
})
```

## 既知の制限

- 複数辞書のマージ・SKKサーバー連携は実装済み（`dict.add_dict()`/`dict.add_dictionary_async()`/`require("skk").setup({ skkserv = {...} })`）。実機の yaskkserv2 での動作確認済み。他の skkserv 実装（`dbskkd-cdb` 等）は未検証。
- 単語登録は実装済み（`vim.fn.input()` の再帰呼び出しによるUI、後述の「単語登録UI」参照）。バッファ・コマンドラインどちらの変換からでも動作し、実機確認済み。
- 通常のバッファ（挿入モード）・コマンドラインモード（`c`、`/`・`?`・`:` いずれも含む）ともに、ローマ字→かな変換・4モード切替・モードインジケーター・辞書変換（`▽`/`▼`、候補選択ウィンドウ）に対応済み（`target.lua`、実機確認済み）。実際の検索・置換（`:%s`）とも問題なく共存する。
- **内蔵ターミナル（`t`）には対応しない方針**とした。理由は以下の2点：
  - （技術的コスト）内蔵ターミナルはNeovimの通常のバッファではなくPTYであり、`nvim_buf_set_text()`のような直接書き込みができず、確定した文字列を`chansend()`でPTYにバイト列として送る形になる。未確定のローマ字断片の literal display や `▽`/`▼` のpreedit表示、それを`<BS>`等で書き換える操作を、PTYへのバイト列送出という一方向的な手段だけで安全に実現するのは実装難易度が大きく上がる。実際、[skkeleton](https://github.com/vim-skk/skkeleton)を内蔵ターミナルで試した際、`<C-j>`で有効化はできるものの確定したはずの文字がターミナルに残らない不具合が実機で確認されている。
  - （費用対効果）内蔵ターミナル上で日本語などの長文を入力する機会はもともと少なく、また内蔵ターミナルではシェル補完は効くが`blink.cmp`のような補完エンジンは機能しないため、このプラグインが元々解決しようとした課題（`blink.cmp`との相性、後述の「なぜ作るか」参照）にとって内蔵ターミナル対応の価値は薄いと判断した。
- `<Left>`/`<Right>` などのカーソル移動キーやマウスクリックは、henkan 非アクティブ時の未確定ローマ字バッファについては安全に扱える（`is_target_key` に該当しないキーが来た時点でバッファを無条件にリセットするため、確定済みかなを破壊するようなバイト列破損は起こらない）が、**表示上の不整合**（未確定ローマ字がそのまま残る）は起こりうる。henkan（▽/▼）アクティブ中にこれらのキーが来た場合の挙動は未検証。
- blink.cmp のネイティブソースとしての統合は、Phase 2（実際の変換候補=漢字まで表示する設計、後述の「blink.cmp ネイティブソース統合」参照）まで実装・実機確認済み。サンドボックス環境（[nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox)）で通常バッファ・コマンドラインモード双方の動作確認が完了しており、`show()` 再トリガーの不具合・外部UIとのキー競合（`passthrough_guard`）も修正済み。実機の日常設定 [nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton) への実際の配線はまだ行っていない。設計上、送りありの前方一致補完は非対応、候補を選ぶ前のライブなゴーストテキストプレビューも出せない。
- `egg_like_newline = false`（SKK本来の、確定+改行の動作）は実装・動作確認済みだが、`vim.api.nvim_feedkeys()` で `<CR>` を再注入する方式のため、`<CR>` に他プラグインのマッピングが被っている環境では想定外の相互作用が起こる可能性がある。
- 候補選択ウィンドウの表示位置自動切替（上下）は `vim.fn.screenpos()` の実測に依存するため、`nvim --headless`（UI未接続）環境ではテストできない（実機での動作確認のみ）。
- モードラインへのモード表示（現状はカーソル位置への一時的なインジケーターのみ）は未実装。

## 開発時の動作確認

普段の Neovim 設定を汚さずに、このリポジトリ単体で動作確認できる最小 init（`skk_test_init.lua`）を同梱している。

```bash
nvim -u ./skk_test_init.lua
```

起動後、挿入モードで `<C-j>` → `ka`・`kka`・`kyou`・`xtu` などを打って変換されるか確認する。モード切替も試す: `q`（ひらがな⇔カタカナ）、`l`（→半角英数）、`L`（→全角英数）。`:SkkMode` で現在のモードを確認できる。

`skk_debug_float.lua` は、コマンドラインモード編集中にフローティングウィンドウが実際に画面へ反映されるかどうかを切り分けるための使い捨てデバッグスクリプト（`nvim -u skk_test_init.lua -c "source skk_debug_float.lua"` で読み込む）。skk.nvim 本体の一部ではないが、コマンドライン向けUI（候補選択ウィンドウ等）の実装・デバッグ時に再び使う可能性があるため当面リポジトリに残してある。

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
2. ~~`vim.on_key()` によるキー横取り~~ ✅
3. ~~4モード（半角英数/ひらがな/カタカナ/全角英数）の相互切替~~ ✅
4. ~~`▽`/`▼` の pre-edit 表示を extmark ベースに置き換える~~ ✅
5. ~~辞書検索（送りなし・送りあり・abbrev）~~ ✅
6. ~~候補選択ウィンドウ（複数候補の一覧表示・ページング）~~ ✅
7. ~~Sticky-shift~~ ✅
8. ~~個人辞書・学習（recency-based の並び替え）~~ ✅
9. ~~複数辞書のマージ・skkserv 連携~~ ✅
10. ~~単語登録（候補が見つからない読みをその場で辞書に追加する）~~ ✅（`vim.fn.input()` の再帰呼び出しによるUI。再帰的な単語登録も可能。実機確認済み、後述の「単語登録UI」参照）
11. ~~blink.cmp ネイティブソースとしての統合~~ ✅（読みのみのライブ補完=v2、実際の変換候補=漢字を出す設計=Phase 2 とも、サンドボックス環境 [nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox) で実機動作確認済み。実機の日常設定への配線が次のステップ、詳細は後述の「blink.cmp ネイティブソース統合」、前述の「既知の制限」参照）
12. ~~周辺 UI（モードインジケーター）~~ ✅（カーソル位置への一時表示のみ。モードライン表示は未着手）
13. ~~コマンドラインモードへの対応~~ ✅（`target.lua`。ローマ字→かな変換・4モード切替・モードインジケーター・辞書変換（`▽`/`▼`、候補選択ウィンドウ）まで実機確認済み。内蔵ターミナルは非対応と決定、前述の「既知の制限」参照）
14. `vim.uv.new_work()` によるスレッドプール並列パース（大きな辞書の起動負荷をさらに削減）

## 参考にしたプロジェクト

- [vim-skk/skkeleton](https://github.com/vim-skk/skkeleton) — 単語登録UI（`vim.fn.input()` の再帰呼び出し、`<Esc>`/`<C-g>` をセンチネル文字列で判定する手法）は `registerWord()`（`denops/skkeleton/function/dictionary.ts`）を実装前に読んで参考にした
- [uga-rosa/skk-learning.nvim](https://github.com/uga-rosa/skk-learning.nvim) — Lua での SKK 実装入門
- [yuys13/skk-develop.nvim](https://github.com/yuys13/skk-develop.nvim) — SKK辞書ダウンローダー
- [wachikun/yaskkserv2](https://github.com/wachikun/yaskkserv2) — skkserv 連携の実機動作確認に使用したSKKサーバー
- [Saghen/blink.cmp](https://github.com/Saghen/blink.cmp) — ネイティブソースのAPI（`get_completions`/`execute`/`resolve`、`default_implementation` を自分で呼ぶ必要がある点等）を `blink_source.lua` 実装前に読んで参考にした
- [nabehan/nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton) — 実機で skkeleton + blink.cmp を運用している設定一式。`skkeleton_source.lua`（textEdit の range 計算、`default_implementation` 呼び出し忘れの教訓）や `blink.lua`（`▽`/`▼` に合わせた show()/hide()、`▼` 中の抑止、キーマップ設定）を `blink_source.lua` 設計時に参考にした。実機が既定の `<C-y>` ではなく `<CR>` を accept に割り当てていた事実は `passthrough_guard` の設計（キー決め打ちではなく `is_visible()` 判定にする）を見直す決め手になった
- [nabehan/nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox) — 実機の日常設定とは切り離して blink.cmp 統合を検証するための、NVIM_APPNAME方式のサンドボックス環境

---

以降は内部実装・設計判断の記録（開発者向け）。

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
├── init.lua              -- エントリーポイント。setup() でキャプチャ層・キーマップ・オプションを登録
├── capture.lua            -- vim.on_key() によるキー入力の横取り・モード/henkanへの振り分け
├── target.lua              -- 書き込み先（挿入モードのバッファ / コマンドライン）の違いを吸収する層
├── mode.lua                -- 4モードの状態遷移ロジック（vim.* 非依存、単体テスト可能）
├── mode_indicator.lua      -- モード切替時、カーソル位置にグリフ（ひら/カタ/latn/ＬＡ）を一瞬表示する
├── context.lua            -- 入力状態（確定済み出力 / 未確定バッファ / 現在モード）を保持するオブジェクト
├── input.lua              -- ローマ字 → かな変換のステートマシン本体
├── kana_table.lua          -- ローマ字 → ひらがな 変換テーブル（子音×母音から機械的に生成）
├── kana_util.lua           -- ひらがな⇔カタカナ⇔全角英数の相互変換
├── encoding.lua            -- 辞書ファイルの文字コード変換（vim.fn.iconv() のラッパー）
├── blink_source.lua        -- blink.cmp 用ネイティブソース（▽状態でのライブ前方一致補完）
├── henkan/                -- ▽/▼（漢字変換）の状態機械と見た目
│   ├── state.lua            -- 状態機械本体（idle/midashi/select/abbrev）。capture.lua から呼ばれる
│   ├── session.lua          -- 1回の変換セッションが持つ読み・候補・ページ状態
│   ├── preedit.lua          -- ▽/▼ の見た目を extmark の仮想テキストで表示する
│   └── candidate_window.lua -- 複数候補一覧をフローティングウィンドウで表示する
└── dict/                  -- 辞書
    ├── init.lua              -- 検索インターフェース（lookup）
    ├── jisyo_parser.lua      -- SKK辞書形式（SKK-JISYO）のパーサ
    └── file_source.lua       -- 辞書ファイルの読み込み（文字コード変換込み）
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

未確定のローマ字断片（例: `"k"` だけ打った直後、まだ変換表のどのエントリにも完全一致していない状態）は、実バッファにそのまま普通の文字として表示しておき、変換が確定した瞬間にその文字数ぶんを消してかなに置き換える方式にしている。実装がシンプルで、何も表示されない不安がないという利点がある一方、本来の SKK の見た目とは異なる。**これは `▽`/`▼`（henkan、下記参照）とは別物**で、henkan 側は `henkan/preedit.lua` による extmark 仮想テキスト表示に既に置き換わっている。

実際のバッファ書き換え (`nvim_buf_set_text`) は `vim.on_key()` のコールバック内で直接行わず、`vim.schedule()` で1ティック遅延させている。[blink.cmp との統合作業](https://github.com/nabehan/nvim-config-blink-skkeleton)で `E565: Not allowed to change text or change window` という textlock エラーを複数回踏んだ教訓から、同種の制約下にある可能性を考慮した予防的な対応。

### コマンドラインモード対応 (`target.lua`)

挿入モードのバッファ操作は `nvim_buf_set_text()` + `nvim_win_get_cursor()` の組だが、コマンドライン（`:`/`/`）はバッファではないためこれらのAPIが使えない。`target.lua` はこの違いを吸収する層で、`capture.lua` はモードを意識せず `target.replace_before_cursor(byte_len, text)` を呼ぶだけでよい。

- **バッファ実装**: 従来通り `nvim_buf_set_text()`。
- **コマンドライン実装**: `vim.fn.getcmdline()`/`setcmdline()`/`getcmdpos()`（いずれも Neovim 0.10+ で追加。前述の `Target: Neovim 0.10+` という前提と矛盾しない）。「カーソル直前の N バイトを削除して置き換える」という純粋なテキスト操作部分（`target._compute_cmdline_replace()`）は `vim.*` に依存しないため単体テスト可能な形に切り出してある。

**モードの分離**: バッファとコマンドラインで `context.mode`（現在の入力モード）を共有すると、「コマンドラインに入っても直前のバッファのモードのまま残る」「コマンドラインで最後に使ったモードがバッファ側に漏れる」という2つの問題が起きる（実機での検証で発見）。`capture.lua` は `CmdlineEnter`/`CmdlineLeave` autocmd でモードを退避・復元し、コマンドラインは常に `cmdline_start_mode`（デフォルト `ascii`）から始まり、抜けるとバッファ側の直前のモードに戻る、という独立した状態として扱う。

**コマンドライン中のフローティングウィンドウには `redraw` が必要**: コマンドライン編集中（Enterを押す前）に新規作成・再配置したフローティングウィンドウは、Neovim の通常の画面再描画サイクルには乗らず、次にコマンドラインを抜けるまで実際には描画されないことを実機で確認した（挿入モードでは次のキー入力ごとに通常の再描画が走るため問題にならない）。`mode_indicator.lua` はコマンドラインモード中、ウィンドウの表示/非表示のたびに明示的に `vim.cmd("redraw")` を呼ぶことでこれに対処している。この知見は今後の候補選択ウィンドウのコマンドライン対応にもそのまま適用する。

**henkan（`▽`/`▼`、辞書変換）のコマンドライン対応**: `henkan/preedit.lua` はコマンドラインでは extmark を使わず、コマンドライン文字列そのものへの直接書き込みで `▽`/`▼` を表示する（ddskk/skkeleton と同様の方式。anchor時点の `getcmdpos()` を基準に、表示中のマーカーテキストの長さを追跡し、更新のたびに削除→挿入し直す）。候補選択ウィンドウ（`henkan/candidate_window.lua` の `M.show_cmdline()`）は `relative="editor"` でコマンドライン行のすぐ上に固定表示し、上記の `redraw` 強制もあわせて適用する。実際の検索（`/`・`?`）・置換（`:%s`）の一部として変換した文字列がそのまま使われても問題なく動作することを実機で確認済み。内蔵ターミナルへの対応は行わない方針（前述の「既知の制限」参照）。

### 変換（`▽`/`▼`、henkan）(`henkan/`, `dict/`)

未確定バッファが空の状態で大文字キーが来ると `henkan/state.lua` の状態機械（`idle` → `midashi`（▽） → `select`（▼））が始まる。変換セッション中は実バッファに一切書き込まず、`henkan/preedit.lua` が extmark の仮想テキスト（inline）で `▽よみ`/`▼候補` を表示し続け、確定した瞬間にだけ実バッファへ挿入する（`<BS>` で読みを取り消しても実バッファには何の影響もなく安全、という設計）。

**開始トリガーは3種類:**

| トリガー                       | 例            | 動き                                                                                                                                                                                                                                        |
| ------------------------------ | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 大文字キー                     | `Kanji<SPC>`  | Shift+文字で ▽開始とその1文字目を同時に指示する、本家 SKK の標準操作                                                                                                                                                                        |
| Sticky-shift（デフォルト `;`） | `;kanji<SPC>` | Shift操作を回避し、`;` で ▽開始・送り開始点だけを指示する（[ddskk の説明](https://ddskk.readthedocs.io/ja/latest/06_apps.html)）。`;` 自体は文字を持たないマーカー。`sticky_shift_enabled`/`sticky_shift_key` で有効・無効/キーを変更できる |
| `/`（abbrev）                  | `/Bug<SPC>`   | ローマ字→かな変換を経由せず、ASCII文字列そのものを見出しにする（`henkan/session.lua` の `input_abbrev`）。英単語をそのまま見出しにしたい辞書エントリ用                                                                                      |

**送りあり変換**は、▽の中でもう一度大文字キー（または Sticky-shift キー）が来ると `state.lua` の `start_okuri()` が送り開始点を設定し、以降のローマ字入力は送り仮名側に切り替わる。子音+母音が確定した瞬間に自動で辞書検索（▼への遷移）が起きる（スペース不要）。

**候補選択ウィンドウ**（`henkan/candidate_window.lua`）は `▼` 遷移時にフローティングウィンドウで開く（`candidate_window.threshold` で表示タイミングを遅らせることもできる。後述）。1ページ最大7候補、ホームポジション `a s d f j k l` を上から割り当て、押すとその位置の候補を即選択・確定する。`<SPC>` で次の7候補（次ページ）、`x` で前の7候補（前ページ）。`<C-n>`/`<C-p>` で候補を1件ずつフォーカス移動でき（ページ境界は次/前ページへ折り返す）、フォーカス中の候補は行ハイライト（`SkkHenkanCandidate`）で示される。`<CR>`/`<C-j>` でフォーカス中の候補を確定する。辞書のアノテーション（`候補;注釈`）があれば `candidate_window.annotation`（デフォルト on）に応じて表示する。最下行には `candidate_window.page_indicator`（デフォルト on）に応じて `"現在ページ/全ページ数"`（例: `"2/3"`）を表示する。

**候補ウィンドウの表示タイミング**は `candidate_window.threshold`（デフォルト 2）で調整できる。個人辞書の学習で先頭候補が当たりやすくなったことを踏まえ、`<SPC>` を押した回数がこの値に達するまではインラインの `▼候補` 表示で1件ずつ候補を送るだけにし、ウィンドウ自体は表示しない（1にすると、従来通り最初の `<SPC>` で即座にウィンドウも表示する）。**ウィンドウが実際に表示されている間だけ**、ホームポジションキー（`a s d f j k l`）は候補選択として扱う。表示前（インラインプレビューのみの段階）は、見えていない選択肢を選ばせる形になって誤確定につながるため、これらのキーも他の文字と同様「インライン表示中の候補を確定して、そのキー自体は新しい入力として続ける」動作になる（`henkan/state.lua` の `is_candidate_window_visible()` が判定する）。

表示位置はプレエディット行の直下が基本だが、画面下端までの残り行数が候補ウィンドウの高さ（枠線込み）より少ない場合は直上に表示する（`vim.fn.screenpos()` で実測）。一度どちらかに決めたら、そのセッション中（`<SPC>`/`x` でページを送って候補数が変わっても）は同じ側に出し続ける（sticky）。視線移動を減らすための仕様で、確定・キャンセルすると次のセッションでは再計算される。

**辞書**（`dict/`）は SKK-JISYO 形式（`;; okuri-ari entries.` / `;; okuri-nasi entries.` セクション、`よみ /候補1/候補2;注釈/` 形式）を `jisyo_parser.lua` でパースする。読み込みには2通りある:

- `dict.set_dict(jisyo_parser.parse(text))` — 同期・全件パース。テストや小さい辞書向け。
- `dict.load_dictionary_async(path, encoding, on_done)` — 非同期・遅延パース。大きな辞書（SKK-JISYO.L・LL 等、数MB〜十数MB）向け。以下の2段構えで、Neovim の起動や編集操作をブロックしないようにしている。
  1. ファイル読み込み・文字コード変換・「読み → 生の候補文字列」への軽量インデックス化を `vim.schedule()` で起動完了後まで遅延させ、インデックス化本体は一定の時間予算（デフォルト30ms）ごとにイベントループへ譲歩しながら進める。候補文字列そのものはこの時点ではまだパースしない。
  2. 実際の候補パースは、そのreadingが検索（lookup）された瞬間に初めて行い、結果をメモ化する。巨大な辞書でも実際に引かれるreadingは全体のごく一部なので、体感の起動負荷をさらに減らせる。

実測（17MB・52万行、この開発環境の Lua 5.4）では、同期の全件パースが約4秒かかっていたのに対し、非同期・遅延パースは約2.1秒で完了し、かつその間 Neovim は固まらない。実際の Neovim は LuaJIT で動く（この開発環境の Lua 5.4 より一般に高速）ため、実機ではさらに短くなる見込み。denops のような外部プロセスを使う実装（例: skkeleton）に比べると、単一スレッドでの協調的なスケジューリングである以上、体感の「瞬間起動」には及ばない可能性がある。`vim.uv.new_work()`（libuv スレッドプールを使った真の並列パース）でさらに縮められる可能性はあるが、ワーカースレッドはクロージャや `vim.*` にアクセスできない等の制約があり、実機での検証を重ねながら慎重に進める必要がある（未着手）。

**複数辞書**は `dict.add_dict(dict, name)`（同期）/ `dict.add_dictionary_async(path, encoding, on_done, time_budget_ms, name)`（非同期・遅延パース）で追加登録できる。優先順位は登録順（先に追加したソースの候補が優先され、`word` が重複する候補は後から追加したソース側は無視される）。`dict.set_dict()`/`dict.load_dictionary_async()` は逆に「唯一のソースとして置き換える」動作なので、複数辞書を使う場合は `add_dict`/`add_dictionary_async` を使う。`dict.clear_dicts()` で登録済みのローカル辞書ソースを全て消せる（個人辞書・SKKサーバーの設定は影響を受けない）。

**SKKサーバー**（`dict/skkserv.lua`）は伝統的な SKK server protocol（`skkserv`/`dbskkd-cdb`/`yaskkserv2` 等）への TCP クライアント。`require("skk").setup({ skkserv = { host = "127.0.0.1", port = 1178, encoding = "euc-jp" } })` で有効化する（実機の [yaskkserv2](https://github.com/wachikun/yaskkserv2) で疎通・変換とも動作確認済み）。

プロトコルはコマンドごとに終端記号が異なる点に注意が必要（yaskkserv2 の README「SKK protocol memo」に詳しい）。実装を誤りやすく、実際にこの実装も最初は取り違えていた:

- `"1"`（検索）: client → server は `"1" .. reading .. " "`（**スペース**終端。改行ではない）。server → client は `"1/候補1/候補2/.../\n"`（改行終端）、見つからなければ `"4" .. reading .. "\n"`。
- `"2"`（バージョン確認）: client → server は `"2"` のみ（終端記号なし）。server → client は `"A.B "`（**スペース**終端。改行ではない）。
- `"0"`（切断）: 終端記号なし、応答も無い。

`henkan/state.lua` からの検索は同期APIとして呼ばれるため、内部では非同期TCP通信を `vim.wait()` でポーリングして待つラッパーになっており、サーバーが応答しない場合は `timeout_ms`（デフォルト300ms）で諦めて空配列を返す（Neovim がフリーズしないようにするため）。接続に失敗した場合は5秒間再試行しない（クールダウン）。`debug = true` を設定すると送受信の生データを `vim.notify()` で出力できる（接続確認には `dict.skkserv_version()`/`dict.skkserv_status()`/`dict.skkserv_last_connect_error()` も使える）。プロトコル実装はこのリポジトリ同梱の簡易テストサーバー（`tests/fixtures/fake_skkserv.py`）と実機の yaskkserv2 の両方で検証済み。他のサーバー実装（`dbskkd-cdb` 等）は未検証。

**マージの優先順位**は 個人辞書 > SKKサーバー（有効時） > ローカル辞書ソース（登録順）。`word` が重複する候補は優先順位の高い方だけが残る。

### 単語登録UI (`henkan/state.lua` の `M._trigger_registration()`)

候補が見つからない場合、または候補送り（`<SPC>`/`<C-n>`）で末尾の候補から次へ進もうとした場合（従来は先頭候補へ循環していたが、この循環は廃止した）、単語登録UIが開く。

実装は Neovim 組み込みの `vim.fn.input()` の**再帰呼び出し**を使う。`input()` は呼び出し中も `mode()=="c"` を維持し、終了後は呼び出し元（挿入モードならその続き、コマンドライン編集中ならその続きのコマンドライン）へ自動的に復帰する性質があり、この性質のおかげで既存の `target.lua`/`preedit.lua` のコマンドラインモード対応（ローマ字→かな変換・henkan）が、登録UI専用のコードを書かなくてもそのまま動く。バッファ起点・コマンドライン起点のどちらの変換からでも同じコードパスで登録UIが動作し、**登録UIの中でさらに変換して未知語を登録する、SKKならではの再帰的な単語登録**も自然に成立する（同じ `henkan_state` モジュールを再帰的に使い回すだけで、専用のスタック管理は不要——`_trigger_registration()` はその時点の変換セッションを確定・キャンセルいずれかで完全に終了させてから `input()` を呼ぶため、「呼び出し元へ戻る」概念自体が無い）。[denops版skkeleton](https://github.com/vim-skk/skkeleton) の `registerWord()`（`function/dictionary.ts`）を実装前に参照し、`vim.fn.input()` の再帰呼び出しを使う点、`<Esc>`/`<C-g>` をセンチネル文字列+`<CR>`に一時的に再マップしてキャンセル判定する点は、ほぼ同じ設計であることを確認している。

- 登録UIに入った瞬間は自動的にひらがなモードで始まる（`capture.lua` の `M.reserve_next_cmdline_mode()` で次のコマンドラインモードの開始モードを1回だけ予約する仕組み。変換操作を行う機会が圧倒的に多いため、毎回 `<C-j>` する手間を省く）。
- `<Esc>`/`<C-g>`、または空欄で `<CR>` した場合はキャンセル扱いで、辞書には書き込まず、登録UIに入る直前に画面表示されていたテキスト（`▽`読みのみ、または `▼`候補）をそのまま確定する。
- 単語を入力して `<CR>` すると `dict.record_selection()` で個人辞書に書き込まれ、その単語（+送り仮名）が確定する。
- `▽`/`▼` のマーカー表示は `vim.fn.input()` を呼ぶ**前**に消す（呼んだ後だと、ネストした変換が `preedit.lua` の内部状態を上書きしてしまい、マーカーが消えずに残ったまま新しい単語が挿入される不具合があった。実機で発見・修正済み）。

### blink.cmp ネイティブソース統合 (`blink_source.lua`)

skk.nvim は [blink.cmp](https://github.com/Saghen/blink.cmp) のネイティブソースとしても動作する（`sources.providers` への登録自体はこのプラグインの外、ユーザー設定側の責務。前述の「使い方」参照）。`▽`/abbrev（見出し語入力中）状態のときだけ `dict.lookup_prefix()` による前方一致検索の結果をライブ補完候補として出す（denops版 skkeleton の `getCompletionResult()` 相当）。

**v2（経緯）**: 最初の実装（v1）は前方一致で見つかった読みごとに無条件で実際の変換候補（`"1"` コマンド）まで取得していたが、1回のキー入力で最大 `max_items+1` 回もの同期TCPラウンドトリップが発生しうる構造的な問題があった（下記「SKKサーバーとの通信の信頼性」参照）ため、v2 ではライブ補完で返すのを前方一致する**読みの一覧**のみに絞っていた。

**Phase 2（現在の設計）**: v2 の「安全だが漢字が見えない」制約を解消し、個人辞書・ローカル辞書・SKKサーバーのどれについても実際の変換候補（漢字）まで取得して出すようにした。個人辞書・ローカル辞書は `M.lookup()` がインメモリの同期処理なので何件呼んでもコストは無視できるが、SKKサーバーへの `"1"` 呼び出しには（1）往復回数、（2）`dict.lookup_prefix()` が返す読みが個人辞書・ローカル辞書・SKKサーバーの「和集合」であるがゆえの notfound フォールバック地雷（下記参照）の2つのリスクがある。これを避けるため、`dict.lookup_prefix()` の第2戻り値 `from_skkserv`（SKKサーバー自身の `"4"` 応答に含まれていた読みだけの集合）を使い、SKKサーバーへ `"1"` を投げるのは「`from_skkserv` に入っている読みに限り、かつ件数上限（`blink.skkserv_candidate_limit`、既定20件）まで」に絞っている。**ただしこれだけでは(2)を完全には防げないことが実機で判明した**ため、読みに `(` `)` `"` `\` 等（SKKのプログラム候補構文で使われる文字）が含まれる場合は `from_skkserv` に入っていても `"1"` を送らない追加の防御も入れている（詳細は下記「SKKサーバーとの通信の信頼性」の6番目の項目参照）。上限を超えた分・`from_skkserv` に無い読み・上記の防御に該当する読み・候補が1件も見つからなかった読みは、v2 と同じ「読みのみ」のフォールバック項目になる（選ぶと `M.set_reading()` で読みが置き換わるだけで `▽` のまま）。

候補そのもの（`data.word` あり）を選んで確定（`execute()`）すると、v1と同様 `henkan/state.lua` の `M.confirm_external(reading, false, word, annotation)` に委譲し、個人辞書への学習・実テキストの挿入まで一気に行って `▽`/`▼` 状態を終了する。読みのみのフォールバック項目を選んだ場合は `M.set_reading()` で読みが置き換わるだけで、従来通り `<SPC>` で `▼`（実際の変換候補選択）に進む。

`require("skk").setup({ blink = { skkserv_candidates = false } })` で SKKサーバーへの `"1"` 呼び出しそのものを完全に止められる（個人辞書・ローカル辞書の候補のみになる。`"4"` による読み一覧の取得を制御する `skip_skkserv` とは独立したスイッチ）。

**設計上の重要な違い（skkeleton用ソースとの比較）**: skkeleton は `▽`/`▼` を実バッファへの直接書き込みで表示するため、実機で運用している `skkeleton_source.lua` は「実テキストの範囲を textEdit で置換する」方式が使える。一方 skk.nvim の `▽`/`▼` は extmark（仮想テキスト）表示で、実バッファには何も書き込まれていない。そのため `blink_source.lua` では textEdit を「今のカーソル位置への空挿入（no-op）」にとどめ、実際の状態更新は `execute()` から `M.set_reading()` に委譲する。

**表示の連動**: `henkan/state.lua` は `▽`/`▼` の状態変化のたびに `User autocmd "SkkHenkanChanged"`（skkeleton の `skkeleton-mode-changed` 相当）を `data.phase`/`data.reading`/`data.has_okuri`/`data.source_mode` 付きで発火する。blink.cmp メニューの show()/hide() 自体はこのソースの責務ではなく、ユーザー設定側でこの autocmd を見て行う想定（実機の `nvim-config-blink-skkeleton` の `skkeleton-mode-changed` ハンドラと同じ考え方）。`▼`（候補選択）中は skk.nvim 自身の候補選択ウィンドウと表示が競合するため、blink.cmp 側は抑止するのが前提。

#### 実装上の既知のクセ（実機で発見）

- **`show()` の再トリガー**: `▽` の間、読みが1文字変わるたびに `SkkHenkanChanged` は毎回発火するが、blink.cmp の `show()` は「メニューが既に開いていて `providers` を指定しない場合は何もしない」というガードを持つ。skkeleton なら実バッファのテキスト変化で blink.cmp 自身の自動再取得に乗れるが、skk.nvim の `▽`/`▼` は extmark 表示で実バッファが変化しないため乗れない。ユーザー設定側で `show()` を呼ぶときは必ず `providers = { "skk" }` を明示し、メニューが開いているかどうかに関わらず毎回強制的に再トリガーする必要がある（省略すると、▽に入った直後の1回目でメニューが開いた後、読みが伸びても候補リストが更新されないまま止まる）。詳細は前述の「使い方」のサンプルコード参照。
- **コマンドラインモードでの range 計算**: `enter_key` は挿入モードだけでなくコマンドラインモード（単語登録UIの `vim.fn.input()` 等）にもマップされるため、コマンドラインモード中に `▽` 変換が行われることがある。blink.cmp 自身がコマンドラインモードでは「行番号は常に0」という前提を置いているため、`get_completions()` の textEdit range 計算はコマンドラインモードかどうかで分岐させる必要がある（通常バッファの行番号をそのまま使うと候補プレビュー処理がクラッシュする）。実装済み。
- **キーワード抽出との衝突**: blink.cmp 本体は、どのソースの候補であっても一律に「実バッファのカーソル位置から独自に抽出した『キーワード』」（Unicode の「文字」カテゴリ基準。漢字を含む）を問い合わせ文字列として、各候補の `filterText`（無ければ `label`）に対してファジーマッチをかける（`completion/list.lua` の `list.fuzzy()`）。`is_incomplete_forward`/`is_incomplete_backward` に関わらず必ず行われ、ソース側でバイパスする公式な手段は無い。カーソル直前に実テキストとして漢字や英数字が続いていると、それが丸ごと「キーワード」として抽出され、こちらが返す `filterText`（読みそのもの）とほぼ一致しないためフィルタで全滅し、候補ウィンドウ自体が開かない。対策として `get_completions()` は blink.cmp 自身が実際に抽出するのと同じ関数（`blink.cmp.fuzzy.get_keyword_range()`）を呼んで抽出結果を先読みし、`filterText` の先頭に前置している（blink.cmp の非公開に近い内部実装に依存しているため、blink.cmp のアップデートで壊れる可能性がある。`pcall` で保護済み）。
- **abbrev モードの対称性**: abbrev モード（`/` から始める、見出しが ASCII 文字列そのものになるモード）でも `▽` と同様にライブ補完が効くべきだが、当初 `get_completions()` が `phase == "midashi"` のみを対象にしていたため、abbrev モード中は候補ウィンドウが一切出ない不具合があった。`henkan/state.lua` の実際の変換候補検索（`M.space()`/`M.search()`）は元々 `"midashi"` と `"abbrev"` を対称に扱っているため、`get_completions()` の phase 判定にも `"abbrev"` を追加して修正済み。ユーザー設定側の `enabled()` と `SkkHenkanChanged` ハンドラの phase 判定にも、同様に `"abbrev"` を含める必要がある（前述の「使い方」参照）。

#### 外部UI（blink.cmp）とのキー競合と `passthrough_guard`（実機で発見・重要）

`capture.lua` は `vim.on_key()` で全キー入力を監視しているが、**`vim.on_key()` は観測専用のAPIで、他プラグイン（blink.cmp）が `vim.keymap.set()` で明示的にバインドしたキーの発火そのものは止められない**。そのため、`▽`/abbrev 中に blink.cmp の accept 等に割り当てられているキーが来ると、次の2つが**独立に、同時に**発火してしまう不具合があった。

1. blink.cmp 自身のキーマップ（`execute()` → `set_reading()`。意図通り）
2. skk.nvim 側の「未対応キー（`<CR>` 含む）は、そのままの読みを確定して `▽` を抜ける」という自動確定ロジック（`henkan_state.confirm()`。実バッファへの本当の挿入 + `▽` 状態の終了を伴う）

blink.cmp の既定キーマップ（`<C-y>` = accept）で検証していたときは気づかなかったが、実機の設定（[nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton)）は `keymap.preset = "none"` の全面カスタムで、`<C-y>` ではなく `<CR>` を accept に割り当てていた。**特定のキーを決め打ちで「blink.cmp用に予約」する対策は、こうした環境では機能しない**（`<CR>` は元々 skk.nvim 自身が「確定」の意味で使うキーでもあるため、決め打ちリストに含めても本質的な解決にならない）。

対策として、`capture.lua` に `M.set_passthrough_guard(fn)` を追加した。`fn(key)` が `true` を返す間、`▽`/abbrev 中の `<CR>`・「未対応キー」による自動確定ロジックを一切実行しない（キーの種類は問わない）。`blink_source.lua` の `source.setup()` は、この `fn` として `require("blink.cmp").is_visible()`（メニュー or ゴーストテキストが見えているかを返す、キー割り当てに依存しない公開API）を自動的に登録する。**「特定のキー」ではなく「外部UIが今まさに見えているか」で判定する**ことで、ユーザーが blink.cmp 側でどのキーをどう割り当てていても機能する。

なお `vim.on_key()` の性質上、skk.nvim 側がこのガードで自分の処理を止めても、blink.cmp 自身のキーマップの発火を妨げる・妨げられるわけではない（そちらは元々 Neovim の通常のキーマップ解決で独立に処理される）。このガードの目的は「skk.nvim 側が重複して確定処理をしてしまう」ことを防ぐことにある。ローマ字の読み入力そのもの（`is_target_key` に該当する文字）は、外部UI表示中でも従来通り継続できるよう対象外にしてある。回帰テストは `tests/capture_henkan_routing_spec.lua` の「外部UI（blink.cmp等）への委譲（passthrough_guard）」参照。

#### SKKサーバーをライブ補完にも含める

`skip_skkserv`（既定 `false`）は、前方一致検索（`"4"` コマンド、読み一覧の取得）にSKKサーバーを含めるかどうかを制御する。既定で有効（skkeleton と同じくSKKサーバーの前方一致結果も含める）。`"4"` コマンドのハンドラには google-japanese-input のフォールバックが無いことを確認済みなので、`"1"` 系のような遅延リスクは無い想定。気になる場合は `require("skk").setup({ blink = { skip_skkserv = true } })` で個人辞書・ローカル辞書のみに絞れる。

`skkserv_candidates`（既定 `true`）・`skkserv_candidate_limit`（既定20）は、実際の変換候補取得（`"1"` コマンド）へのSKKサーバーの関与を制御する、`skip_skkserv` とは独立したスイッチ。詳細は上記「Phase 2（現在の設計）」参照。

#### SKKサーバーとの通信の信頼性（実機で発見・重要、時系列順）

`skip_skkserv = false` を実機で検証する過程で、いくつもの遅延・タイムアウト・応答取り違えの問題を発見・修正した。

1. **TCP_NODELAY 未設定**: Nagle のアルゴリズムと受信側の遅延ACKが組み合わさり、`"1<reading> "` のような小さいリクエストの往復のたびに ~40ms 前後の遅延が発生していた（ローカルホストでも起きる、TCPの典型的な落とし穴）。1回の見出し語入力につき最大 `max_items+1` 回もこの往復が発生しうる設計のため、積み重なって数秒単位の遅延になっていた。`connect_to_ip()` で `sock:nodelay(true)` を呼ぶよう修正済み。
2. **応答の取り違え（再入）**: 接続を1本だけ使い回し「次に届いた1行 = 今送ったリクエストへの応答」とみなす `send_request_and_wait()` の前提が、`vim.wait()` の待機中もイベントループが回る（＝キー入力処理が普通に進む）ことによる**再入**で崩れることがあった。初期対策の `in_flight` フラグ（衝突したら即座に諦める）は衝突は防いだが、リクエストが黙って欠落する副作用があった。最終的に、衝突したリクエストを「捨てる」のではなく「順番待ちのキューに積む」直列キュー方式（`enqueue()`）に置き換えた（詳細は上記「SKKサーバー」節）。
3. **候補パースのオーバーヘッド**: `_parse_response()` が候補1件ごとに `vim.fn.iconv()` を呼んでいたため、候補数の多い読み（数百件になることがある）で体感できるレベルに遅くなっていた。応答本体を1回だけ丸ごと UTF-8 に変換してから候補に分割するよう修正済み（`M._parse_prefix_response()` も同様）。
4. **タイムアウト後の残留データ**: `send_request_and_wait()` はタイムアウトしても接続を閉じていなかったため、OS側のソケット受信バッファに残った「遅れて届いた応答」を、次の無関係なリクエストへの応答として誤って受け取ってしまうことがあった。タイムアウト時は接続を `close()` して `client = nil` にし、次回は必ず新しい接続を張り直すよう修正済み。
5. **辞書側の変則エントリ**: 上記4の引き金として、`jawiki` 辞書に含まれる `t(concat "\057")c`（SKKのプログラム候補構文がそのまま読みとして紛れ込んだもの）のような、読みの中に空白を含む変則エントリが、`M._parse_prefix_response()` の以前のトークナイズ（空白でも区切っていた）によって誤分割され、存在しない断片をサーバーに問い合わせる原因になっていた。区切りを `"/"` のみにするよう修正済み。
6. **Phase 2の from_skkserv だけでは防ぎきれない notfound フォールバック（実機で発見・重要）**: 上記の Phase 2 は、SKKサーバー自身が `"4"` で存在を表明した読み（`from_skkserv`）に限って `"1"` を送ることで notfound フォールバックを避ける設計にしていたが、これだけでは不十分だった。`jawiki` 辞書に含まれる `a(concat ...)` のような上記5と同系統の変則エントリ（プログラム候補構文が読みに紛れ込んだもの）について、yaskkserv2 の `"4"`（前方一致）では見つかるのに `"1"`（完全一致）では notfound になり、`google-japanese-input` フォールバック（Google 翻訳の `transliterate` API への問い合わせ。既定は `notfound` 時のみ発動）がタイムアウトして詰まる事象が実機で確認された。abbrev モード（ASCII文字列をそのまま前方一致検索する）はこの種の変則エントリに当たりやすく、かつ辞書内でソート順が先頭に来やすいため、`skkserv_candidate_limit` を絞っても発生しうる。追加の防御として、読みに `(` `)` `"` `\` や制御文字が含まれる場合は `from_skkserv` に入っていても `"1"` を送らないようにした（`blink_source.lua` の `looks_safe_for_skkserv_lookup()`）。より根本的には、yaskkserv2 側の設定 `google-japanese-input = disable`（既定は `notfound`）でこのフォールバック自体を無効化することもできる。

**送りありの前方一致補完は現時点で提供していない**（`dict.lookup_prefix()` は okuri-nasi のみに絞っている。プロトコル・実用上の理由による）。

#### 実機での検証状況

独立したサンドボックス環境（[nvim-skk-sandbox](https://github.com/nabehan/nvim-skk-sandbox)）で、通常バッファ・コマンドラインモードの両方について、ライブ補完の表示・更新（Phase 2の変換候補=漢字表示を含む）・`<C-n>`/`<C-p>` での選択・確定・`<SPC>` でのskk.nvim本来の変換への移行まで、応答速度を含めて動作確認済み。`skkserv_candidate_limit`（既定20）は実機で「とてもスムーズ」と確認されており、増やす余地もある。`tests/blink_source_spec.lua`（Phase 2のテスト含む）も blink.cmp を rtp に含めた実機の `test.sh` 実行で全件Success。実機の日常設定（[nvim-config-blink-skkeleton](https://github.com/nabehan/nvim-config-blink-skkeleton)）への実際の配線はまだ行っていない。

### モードインジケーター (`mode_indicator.lua`)

モードが切り替わった瞬間（`<C-j>`、または `l`/`q`/`L`）、カーソル位置にフローティングウィンドウでグリフ（`ひら`/`カタ`/`latn`/`ＬＡ`）を表示する。実際に次のキー入力があった時点で消える（`capture.lua` の `on_key()` が毎回呼ぶ `mode_indicator.hide()` が担当する）。

`<C-j>` によるモード遷移は `vim.on_key()` の `on_key()` を通らず、`init.lua` が `vim.keymap.set()` 経由で `capture.transition()` を直接呼ぶ別ルートなので、インジケーター表示もそちらで個別に行っている（過去、ここが漏れて `<C-j>` だけインジケーターが出ない不具合があった）。

## ライセンス

[MIT License](LICENSE)
