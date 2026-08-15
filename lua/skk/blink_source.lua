-- lua/skk/blink_source.lua
--
-- blink.cmp 用のネイティブソース。`▽`/abbrev（見出し語入力中）状態の
-- ときだけ、dict.lookup_prefix() による前方一致検索の「読み一覧」を
-- ライブ補完として出す。
--
-- 【設計方針・v2（skkeleton 方式に合わせた）】
-- 実機での性能検証の結果、以前の実装（前方一致で見つかった読みごとに
-- 実際の変換候補まで dict.lookup()（"1" コマンド）で取得し、漢字候補
-- そのものを補完メニューに出す設計）には、次の構造的な問題があった:
--
--   - 1回のキー入力につき最大 max_items+1 回もの dict.lookup() 呼び出しが
--     発生する（前方一致で最大 max_items 件の読みが見つかった場合）。
--   - SKKサーバーを有効にすると、"1" コマンドのハンドラ側で
--     google-japanese-input（既定値 "notfound"）が有効な限り、
--     ローカル辞書で見つからなかった読みのたびに SKKサーバーが
--     Google 日本語入力へのオンラインHTTPS問い合わせにフォールバックし、
--     1回で数秒単位の遅延になることがある（実機で発見。yaskkserv2 の
--     src/skk/yaskkserv2/dictionary_reader.rs の read_candidates() 参照。
--     google-suggest とは別の、独立した設定であることに注意）。
--   - 1回のキー入力で最大 max_items+1 回も踏むため、この「たまに重い」
--     経路に当たる確率が跳ね上がる。
--
-- skkeleton（denops/skkeleton/sources/skk_server.ts の
-- getCompletionResult()）は、ライブ補完では "4"（前方一致）だけを呼び、
-- 実際の変換候補（"1"）は選択・確定の段階まで一切取得しない設計だった。
-- これにより「1回のキー入力で最大1回の "4" のみ」に抑えられており、
-- "1" 由来の遅延（Googleフォールバック含む）をライブ補完中に踏むことが
-- そもそも無い。
--
-- 本ソースもこれに合わせ、v2 では **ライブ補完に出すのは読み一覧のみ**
-- とし、blink.cmp のメニューで読みを選ぶと `▽`/abbrev の読みがその読みに
-- 置き換わるだけ（henkan/state.lua の M.set_reading()）で、実際の変換候補
-- （▼）には進まない。従来通り <SPC> で ▼ に進む。
--
-- 【使い方】blink.cmp の設定（sources.providers）に以下のように登録する:
--
--   sources = {
--     default = { "skk", "lsp", "path", "snippets", "buffer" },
--     providers = {
--       skk = {
--         name = "skk",
--         module = "skk.blink_source",
--         enabled = function()
--           local phase = require("skk.henkan.state").get_phase()
--           return phase == "midashi" or phase == "abbrev"
--         end,
--       },
--     },
--   }
--
-- `▽`/`▼` の表示に合わせて blink.cmp の補完メニューを show()/hide() する
-- には、henkan/state.lua が発火する User autocmd "SkkHenkanChanged" を
-- 使う（data.phase を見る）。設定例は README.md の「blink.cmp 連携」
-- セクションを参照。
--
-- 【設計上の重要な注意（skkeleton 用ソースとの決定的な違い）】
-- skkeleton は `▽`/`▼` を実バッファへの直接書き込みで表示するため、
-- skkeleton_source.lua は「実テキストの範囲を textEdit で置換する」方式
-- が使えた。一方 skk.nvim の `▽`/`▼` は extmark（仮想テキスト）表示で、
-- 実バッファには何も書き込まれていない。そのため同じ方式は使えない。
--
-- このソースでは textEdit を「今のカーソル位置への空挿入」（no-op）に
-- とどめ、実際の状態変更（読みの置き換え）は execute() の中で
-- henkan/state.lua の M.set_reading() に委譲する。

---@module 'blink.cmp'
---@class blink.cmp.Source
local source = {}
source.__index = source

--- require("skk").setup({ blink = { ... } }) から lua/skk/init.lua 経由で
--- 差し込まれる設定。
---@type { max_items: integer, debug_timing: boolean, skip_skkserv: boolean }
local config = { max_items = 50, debug_timing = false, skip_skkserv = false }

---@param opts { max_items: integer?, debug_timing: boolean?, skip_skkserv: boolean? }|nil
function source.setup(opts)
  opts = opts or {}
  if opts.max_items ~= nil then
    config.max_items = opts.max_items
  end
  if opts.debug_timing ~= nil then
    config.debug_timing = opts.debug_timing
  end
  if opts.skip_skkserv ~= nil then
    config.skip_skkserv = opts.skip_skkserv
  end
end

function source.new()
  return setmetatable({}, source)
end

--- skk.nvim は SkkHenkanChanged autocmd で表示/非表示を通知するため、
--- 特定の trigger_characters は不要（skkeleton_source.lua と同じ考え方）。
function source:get_trigger_characters()
  return {}
end

function source:get_completions(_, callback)
  local henkan_state = require("skk.henkan.state")
  local dict = require("skk.dict")

  -- abbrev モード（"/" 開始、見出しがASCII文字列そのものになる）も
  -- 対象にする（実機で発見：以前は "midashi" 限定にしていたため、
  -- abbrev モードで候補ウィンドウが一切出ない不具合があった）。
  local phase = henkan_state.get_phase()
  if phase ~= "midashi" and phase ~= "abbrev" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local reading = henkan_state.current_reading()
  if not reading or reading == "" then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  -- 【暫定の計測ログ】require("skk").setup({ blink = { debug_timing = true } })
  -- で有効化すると、この get_completions() 1回あたりの所要時間を
  -- vim.notify() に出す。
  local t_start = config.debug_timing and vim.loop.hrtime() or nil

  -- 送りありの前方一致補完は現時点で提供していない（dict.lookup_prefix()
  -- の設計を参照。プロトコル・実用上の理由で okuri-nasi のみに絞っている）。
  --
  -- 【設計 v2】ここで取得するのは「読み一覧」のみ（"4" コマンド相当）。
  -- 各読みの実際の変換候補（"1" コマンド）は取得しない
  -- （ファイル冒頭の設計方針コメント参照）。skip_skkserv の既定値は
  -- false（skkeleton と同じくSKKサーバーの前方一致結果も含める）。
  -- "4" コマンドのハンドラには google-japanese-input のフォールバックが
  -- 無いことを確認済み（yaskkserv2 の dictionary_reader.rs 参照）ので、
  -- "1" 系のような遅延リスクは無い想定。気になる場合は
  -- require("skk").setup({ blink = { skip_skkserv = true } }) で
  -- 個人辞書・ローカル辞書のみに絞れる。
  local ok, readings = pcall(dict.lookup_prefix, reading, false, config.max_items, config.skip_skkserv)

  if t_start then
    local elapsed_ms = (vim.loop.hrtime() - t_start) / 1e6
    vim.schedule(function()
      vim.notify(
        string.format(
          "[skk.nvim timing] reading=%s readings=%d lookup_prefix=%.1fms",
          reading,
          (ok and readings) and #readings or 0,
          elapsed_ms
        )
      )
    end)
  end

  if not ok or not readings or #readings == 0 then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  -- 【textEdit について】上部のコメント参照。実際には何も編集しない
  -- （newText=""、range は今のカーソル位置ぴったりのゼロ幅）no-op にし、
  -- 実際の状態変更（読みの置き換え）は execute() に委譲する。
  --
  -- 【重要・実機で発見】range の計算はコマンドラインモードかどうかで
  -- 分岐させる必要がある。skk.nvim の enter_key は挿入モードだけでなく
  -- コマンドラインモード（単語登録UIの vim.fn.input() 等）にもマップして
  -- いるため、コマンドラインモード中に ▽ 変換が行われることがある。
  -- blink.cmp 自身の trigger/context.lua は「コマンドラインモードでは
  -- 行番号は常に 0（vim.fn.getcmdline() 相当）」という前提を置いており
  -- （context.get_cursor()/get_line() 参照）、ここで通常バッファの行番号
  -- （nvim_win_get_cursor(0) の行）をそのまま使うと、後続の候補プレビュー
  -- 処理（accept/preview.lua 等）が「Cannot get line number N in cmdline
  -- mode. Only 0 is supported」という assert エラーで落ちる（実機で確認）。
  local is_cmdline = vim.api.nvim_get_mode().mode == "c"
  local row0, col
  if is_cmdline then
    row0 = 0
    col = vim.fn.getcmdpos() - 1
  else
    local win = vim.api.nvim_win_get_cursor(0)
    row0 = win[1] - 1
    col = win[2]
  end
  local range = {
    start = { line = row0, character = col },
    ["end"] = { line = row0, character = col },
  }

  local kind = require("blink.cmp.types").CompletionItemKind.Text

  -- 【重要・実機で発見】blink.cmp 本体は、どのソースの候補であっても
  -- 一律に「実バッファのカーソル位置から独自に抽出した『キーワード』」を
  -- 問い合わせ文字列として、各候補の filterText（無ければ label）に対して
  -- ファジーマッチをかける（completion/list.lua の list.fuzzy() 参照）。
  -- これは is_incomplete_forward/backward の指定に関わらず必ず行われ、
  -- ソース側でバイパスする公式な手段は今のところ無い。
  --
  -- このキーワード抽出（fuzzy/rust/keyword.rs の BACKWARD_REGEX =
  -- `[\p{L}0-9_][\p{L}0-9_-]*$`）は Unicode の「文字」カテゴリを対象に
  -- しており、漢字も対象に含まれる。skk.nvim の ▽/▼ は extmark（仮想
  -- テキスト）表示で実バッファは変化しないため、カーソル直前に実テキスト
  -- として漢字や英数字が続いていると、それが丸ごと「キーワード」として
  -- 抽出されてしまう。抽出された「漢字」等の文字列と、こちらが返す
  -- 読み（例: "かん"）はほぼ一致しないため、フィルタで全滅し、候補
  -- ウィンドウ自体が開かなくなる（間に半角スペースを挟むと、そこで
  -- キーワードが空文字列になり単に全件通過するだけなので症状が出ない）。
  --
  -- 対策として、blink.cmp が実際に抽出するのと同じ関数
  -- （blink.cmp.fuzzy.get_keyword_range()、blink.cmp.config の
  -- completion.keyword.range 設定を使用）をこちらからも呼んで、
  -- blink.cmp が抽出するはずの文字列を先読みし、filterText の先頭に
  -- そのまま前置する。こうすれば、blink.cmp が何を抽出しようと、それは
  -- 常に filterText の先頭一致になるためフィルタで弾かれない。
  -- 【注意】blink.cmp の非公開に近い内部実装（fuzzy.get_keyword_range）に
  -- 依存しているため、blink.cmp のアップデートで壊れる可能性がある。
  -- 呼び出しは pcall で保護し、失敗時は空文字列にフォールバックする
  -- （その場合はこの不具合が再発するだけで、他の動作には影響しない）。
  local real_keyword = ""
  do
    local ok_kw, kw = pcall(function()
      local fuzzy_mod = require("blink.cmp.fuzzy")
      local blink_config = require("blink.cmp.config")
      local line = is_cmdline and vim.fn.getcmdline() or vim.api.nvim_get_current_line()
      local kw_start, kw_end = fuzzy_mod.get_keyword_range(line, col, blink_config.completion.keyword.range)
      return line:sub(kw_start + 1, kw_end)
    end)
    if ok_kw and type(kw) == "string" then
      real_keyword = kw
    end
  end

  local items = {}
  for rank, full_reading in ipairs(readings) do
    table.insert(items, {
      -- 表示するのは読みそのもの（漢字変換候補ではない。上部の設計方針
      -- コメント参照）。
      label = full_reading,
      filterText = real_keyword .. reading,
      -- dict.lookup_prefix() は既に優先順位でソート済みなので、その
      -- 並び順をそのまま sortText に反映する（数値を10桁ゼロ埋めして
      -- 文字列比較でも数値順になるようにする）。
      sortText = string.format("%010d", rank),
      kind = kind,
      textEdit = { range = range, newText = "" },
      data = { reading = full_reading },
    })
  end

  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  return function() end
end

--- 【重要】blink.cmp の accept パイプラインでは、textEdit の適用は
--- execute() に渡される第4引数 default_implementation を自分で
--- 呼び出さない限り一切実行されない（呼び忘れると「確定してもバッファに
--- 反映されない」不具合になる。nvim-config-blink-skkeleton での実例で
--- 確認済み）。このソースの textEdit は no-op（上部コメント参照）なので
--- 実質的には何もしないが、契約上必ず呼ぶ。
--- 実際の状態変更（読みの置き換え）は henkan/state.lua の
--- M.set_reading() に委譲する。skkeleton と同様、これは変換候補の確定
--- ではなく、あくまで読みの補完に留まる。ユーザーは従来通り <SPC> で
--- ▼（実際の変換候補選択）に進む。
function source:execute(_, item, callback, default_implementation)
  default_implementation()

  local data = item.data or {}
  if data.reading then
    local henkan_state = require("skk.henkan.state")
    henkan_state.set_reading(data.reading)
  end

  callback()
end

return source
