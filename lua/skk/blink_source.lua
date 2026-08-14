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
--           return require("skk.henkan.state").get_phase() == "midashi"
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
---@type { max_items: integer, debug_timing: boolean }
local config = { max_items = 50, debug_timing = false }

---@param opts { max_items: integer?, debug_timing: boolean? }|nil
function source.setup(opts)
  opts = opts or {}
  if opts.max_items ~= nil then
    config.max_items = opts.max_items
  end
  if opts.debug_timing ~= nil then
    config.debug_timing = opts.debug_timing
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

  if henkan_state.get_phase() ~= "midashi" then
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
  -- 【重要】skip_skkserv=true を指定する。SKKサーバーを含めてしまうと、
  -- この関数自体が "4" コマンドで1回、さらに下のループで見つかった読みの
  -- 件数（最大 max_items 件）だけ "1" コマンドが飛ぶため、キー入力の
  -- たびに最大 max_items+1 回もの同期TCPラウンドトリップが発生し、
  -- 体感できるレベルで重くなる（実機で発見。詳細は
  -- lua/skk/dict/init.lua の M.lookup_prefix() のコメント参照）。
  -- ライブ補完は個人辞書・ローカル辞書のみで完結させ、SKKサーバーを
  -- 含めた完全な検索は実際の変換確定操作（スペースキー）でのみ行う。
  local ok, readings = pcall(dict.lookup_prefix, reading, false, config.max_items, true)
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
  local win = vim.api.nvim_win_get_cursor(0)
  local row0 = win[1] - 1
  local col = win[2]
  local range = {
    start = { line = row0, character = col },
    ["end"] = { line = row0, character = col },
  }

  local kind = require("blink.cmp.types").CompletionItemKind.Text
  local items = {}
  local rank = 0

  for _, full_reading in ipairs(readings) do
    local candidates = dict.lookup(full_reading, false, true) -- skip_skkserv=true。上のコメント参照。
    for _, cand in ipairs(candidates) do
      rank = rank + 1
      table.insert(items, {
        label = cand.word,
        labelDetails = { description = full_reading },
        filterText = reading,
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
