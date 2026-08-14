-- lua/skk/blink_source.lua
--
-- blink.cmp 用のネイティブソース。`▽`（見出し語入力中）状態のときだけ、
-- dict.lookup_prefix() による前方一致検索の結果をライブ補完として出す
-- （denops版 skkeleton の getCompletionResult() 相当。実装前に
-- vim-skk/skkeleton の denops/skkeleton/function/dictionary.ts、および
-- 実際に blink.cmp と組み合わせて運用されている
-- nvim-config-blink-skkeleton の skkeleton_source.lua を読んで参考にした）。
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
-- （getPreEdit() で得た文字列の分だけ削って新しい単語を挿入する）が
-- 使えた。一方 skk.nvim の `▽`/`▼` は extmark（仮想テキスト）表示で、
-- 実バッファには何も書き込まれていない。そのため同じ方式は使えない
-- （削除すべき実テキストがそこに存在しない）。
--
-- このソースでは textEdit を「今のカーソル位置への空挿入」（no-op）に
-- とどめ、実際の確定処理（extmarkのクリア・個人辞書への記録・実テキスト
-- の挿入）は execute() の中で henkan/state.lua の確定経路
-- （M.confirm_external()）に委譲する。この設計により、候補を選ぶ前の
-- ライブなゴーストテキストプレビューは出せない（メニュー上のラベル表示・
-- 選択・確定そのものは問題なく機能する）というトレードオフがある。

---@module 'blink.cmp'
---@class blink.cmp.Source
local source = {}
source.__index = source

--- require("skk").setup({ blink = { ... } }) から lua/skk/init.lua 経由で
--- 差し込まれる設定。
---@type { max_items: integer, debug_timing: boolean, skip_skkserv: boolean }
local config = { max_items = 50, debug_timing = false, skip_skkserv = true }

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

  -- 【重要・実機で発見】abbrev モード（"/" 開始、見出しがASCII文字列その
  -- ものになる）も対象にする。henkan/state.lua の実際の変換候補検索
  -- （M.space()/M.search()）は "midashi" と "abbrev" を対称に扱っており
  -- （abbrev では session.reading が ASCII 文字列になるだけで、検索キー
  -- として扱う点は同じ）、blink.cmp 側のライブ補完だけ "midashi" 限定に
  -- していたため、abbrev モードで候補ウィンドウが一切出ない不具合があった。
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
  -- で有効化すると、この get_completions() 1回あたりの所要時間（全体・
  -- lookup_prefix・lookup ループの内訳）を vim.notify() に出す。原因調査用
  -- の一時的なコードなので、原因が特定でき次第削除する。
  local t_start = config.debug_timing and vim.loop.hrtime() or nil
  local t_after_prefix

  -- 送りありの前方一致補完は現時点で提供していない（dict.lookup_prefix()
  -- の設計を参照。プロトコル・実用上の理由で okuri-nasi のみに絞っている）。
  --
  -- 【重要】既定では skip_skkserv=true（config.skip_skkserv）を指定する。
  -- SKKサーバーを含めてしまうと、この関数自体が "4" コマンドで1回、
  -- さらに下のループで見つかった読みの件数（最大 max_items 件）だけ
  -- "1" コマンドが飛ぶため、キー入力のたびに最大 max_items+1 回もの
  -- 同期TCPラウンドトリップが発生しうる（詳細は lua/skk/dict/init.lua の
  -- M.lookup_prefix() のコメント参照）。実際どの程度の体感になるかは
  -- 辞書構成やSKKサーバーの実装・応答速度に依存するため、
  -- require("skk").setup({ blink = { skip_skkserv = false } }) で
  -- 無効化し、ライブ補完にもSKKサーバーの候補を含めることができる。
  local ok, readings = pcall(dict.lookup_prefix, reading, false, config.max_items, config.skip_skkserv)
  if t_start then
    t_after_prefix = vim.loop.hrtime()
  end
  if not ok or not readings or #readings == 0 then
    if t_start then
      vim.schedule(function()
        vim.notify(
          string.format(
            "[skk.nvim timing] reading=%s lookup_prefix=%.1fms (0 readings)",
            reading,
            (t_after_prefix - t_start) / 1e6
          )
        )
      end)
    end
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  -- 【textEdit について】上部のコメント参照。実際には何も編集しない
  -- （newText=""、range は今のカーソル位置ぴったりのゼロ幅）no-op にし、
  -- 実際の確定処理は execute() に委譲する。
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
  local items = {}
  local rank = 0

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
  -- かな漢字変換候補（reading="かん" 等）はほぼ一致しないため、
  -- フィルタで全滅し、候補ウィンドウ自体が開かなくなる（間に半角スペース
  -- を挟むと、そこでキーワードが空文字列になり単に全件通過するだけなので
  -- 症状が出ない）。
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

  for _, full_reading in ipairs(readings) do
    local candidates = dict.lookup(full_reading, false, config.skip_skkserv) -- 上のコメント参照。
    for _, cand in ipairs(candidates) do
      rank = rank + 1
      table.insert(items, {
        label = cand.word,
        labelDetails = { description = full_reading },
        filterText = real_keyword .. reading,
        -- dict.lookup() は既に優先順位（個人辞書の学習順）でソート済みな
        -- ので、その並び順をそのまま sortText に反映する
        -- （数値を10桁ゼロ埋めして文字列比較でも数値順になるようにする）。
        sortText = string.format("%010d", rank),
        kind = kind,
        textEdit = { range = range, newText = "" },
        data = { reading = full_reading, word = cand.word, annotation = cand.annotation },
      })
    end
  end

  if t_start then
    local t_end = vim.loop.hrtime()
    vim.schedule(function()
      vim.notify(
        string.format(
          "[skk.nvim timing] reading=%s readings=%d items=%d lookup_prefix=%.1fms lookup_loop=%.1fms total=%.1fms",
          reading,
          #readings,
          #items,
          (t_after_prefix - t_start) / 1e6,
          (t_end - t_after_prefix) / 1e6,
          (t_end - t_start) / 1e6
        )
      )
    end)
  end

  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  return function() end
end

function source:resolve(item, callback)
  local annotation = item.data and item.data.annotation
  if annotation then
    item.documentation = { kind = "plaintext", value = annotation }
  end
  callback(item)
end

--- 【重要】blink.cmp の accept パイプラインでは、textEdit の適用は
--- execute() に渡される第4引数 default_implementation を自分で
--- 呼び出さない限り一切実行されない（呼び忘れると「確定してもバッファに
--- 反映されない」不具合になる。nvim-config-blink-skkeleton での実例で
--- 確認済み）。このソースの textEdit は no-op（上部コメント参照）なので
--- 実質的には何もしないが、契約上必ず呼ぶ。
--- 実際の確定処理は henkan/state.lua の M.confirm_external() に委譲する
--- （個人辞書への記録・extmarkのクリア・実テキストの挿入を一括で行う）。
function source:execute(_, item, callback, default_implementation)
  default_implementation()

  local data = item.data or {}
  if data.reading and data.word then
    local henkan_state = require("skk.henkan.state")
    henkan_state.confirm_external(data.reading, false, data.word, data.annotation)
  end

  callback()
end

return source
