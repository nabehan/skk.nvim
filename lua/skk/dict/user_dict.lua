-- lua/skk/dict/user_dict.lua
--
-- 個人辞書（学習）。
--
-- 本家SKK・skkeleton と同じ「直近確定した候補を先頭に持ってくる」方式
-- （recency-based）で学習する。頻度カウントは持たず、選択のたびに
-- その候補を先頭へ移動（無ければ新規追加）するだけのシンプルな方式。
--
-- 文字コードは常に UTF-8 固定（skkeleton の userDictionary の慣習に合わせる。
-- 個人辞書は skk.nvim 自身が読み書きするファイルなので、SKK-JISYO.L 等の
-- 伝統的な辞書ファイルと違って文字コード変換を考慮する必要が無い）。
--
-- ファイルI/Oは lua/skk/dict/file_source.lua と同様、素の Lua の io.* を
-- 同期的に使う（vim.loop 等の非同期APIは、実際に同期I/Oが問題になってから
-- 導入する方針）。

local jisyo_parser = require("skk.dict.jisyo_parser")

local M = {}

---@type { okuri_ari: table<string, SkkDictCandidate[]>, okuri_nasi: table<string, SkkDictCandidate[]> }
local data = { okuri_ari = {}, okuri_nasi = {} }

---@type string|nil
local path = nil

--- 【重要・実機で発見】以前は record_selection() のたびに毎回 M.save() を
--- 同期的に呼んでおり、変換候補を確定するたび（＝SKK利用でもっとも頻繁な
--- 操作）に個人辞書全体を jisyo_parser.serialize() で直列化してファイルへ
--- 同期書き込みしていた。個人辞書が育つほど serialize() のコストも増える
--- ため、長文入力セッションほど確定のたびのブロッキングが伸びていく
--- （長文の打ち込みテストで「だんだん重くなる」体感の一因になっていた。
--- skkserv側の直列キューのゾンビジョブ不具合とは独立した、別の原因）。
---
--- 【対策】保存を「最後の record_selection() から SAVE_DEBOUNCE_MS だけ
--- 次の record_selection() が来なければ、まとめて1回だけ書く」方式
--- （デバウンス）に変更する。連続して確定が続く間はディスクに触れず、
--- 少し間が空いたタイミングで初めて実際に書き込む。
---
--- 保留中の書き込みを失わないよう、次の2つのタイミングで強制的に
--- 同期フラッシュする:
---   (1) VimLeavePre（Neovim終了時に、確定直後の学習が失われないように）
---   (2) M.load()（辞書ファイルの切り替え・再読み込み時。手元のテスト
---       （record_selection 直後に load() し直して保存内容を確認する類の
---       もの）も、この (2) のおかげで従来通りの挙動のまま動く）
local SAVE_DEBOUNCE_MS = 500
---@type table|nil vim.defer_fn() の戻り値（:stop()/:close() を持つ）
local pending_save_timer = nil
local flush_autocmd_registered = false

--- 保留中の保存があれば、タイマーを止めて即座に（同期的に）書き出す。
--- 保留中の保存が無ければ何もしない。
local function flush_pending_save()
  if not pending_save_timer then
    return
  end
  pcall(function()
    pending_save_timer:stop()
  end)
  pcall(function()
    pending_save_timer:close()
  end)
  pending_save_timer = nil
  M.save()
end

--- Neovim終了時に保留中の保存を取りこぼさないための autocmd を登録する
--- （一度だけ。M.load() のたびに複数登録しないよう guard する）。
local function ensure_flush_on_exit()
  if flush_autocmd_registered then
    return
  end
  flush_autocmd_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = flush_pending_save,
  })
end

--- record_selection() から呼ぶ。SAVE_DEBOUNCE_MS だけ他の呼び出しが
--- 無ければ実際に M.save() を実行する「まとめ書き」のスケジューラ。
--- 既に予約済みのタイマーがあれば、それを止めて予約し直す
--- （＝連続した確定のたびに毎回ディスクへ書きに行くことはしない）。
local function schedule_save()
  if pending_save_timer then
    pcall(function()
      pending_save_timer:stop()
    end)
    pcall(function()
      pending_save_timer:close()
    end)
    pending_save_timer = nil
  end
  pending_save_timer = vim.defer_fn(function()
    pending_save_timer = nil
    M.save()
  end, SAVE_DEBOUNCE_MS)
end

--- 個人辞書ファイルを読み込む（UTF-8前提）。以降の record_selection() は
--- このパスに自動保存する。
--- ファイルがまだ存在しない場合はエラーにせず、空の状態で始める
--- （個人辞書は「まだ何も学習していない」のが正常な初期状態のため）。
---@param file_path string
function M.load(file_path)
  -- 【重要】切り替え・再読み込みの前に、直前のパスに対する保留中の
  -- デバウンス保存があれば必ず先に書き出す（上のコメント参照）。
  flush_pending_save()

  path = file_path
  local f = io.open(file_path, "rb")
  if not f then
    data = { okuri_ari = {}, okuri_nasi = {} }
    ensure_flush_on_exit()
    return
  end
  local text = f:read("*a")
  f:close()
  data = jisyo_parser.parse(text or "")
  ensure_flush_on_exit()
end

--- 現在設定されている個人辞書のパス（M.load() 未実行なら nil）。
---@return string|nil
function M.path()
  return path
end

--- 読みから個人辞書の候補を検索する。
---@param reading string
---@param has_okuri boolean
---@return SkkDictCandidate[] 見つからなければ空配列
function M.lookup(reading, has_okuri)
  local section = has_okuri and data.okuri_ari or data.okuri_nasi
  return section[reading] or {}
end

--- 前方一致で読みの一覧を検索する（blink.cmp ネイティブソースの
--- ライブ補完用）。個人辞書は通常小規模（学習した語のみ）なので、
--- dict/init.lua の他ソースと違いソート済みインデックスは持たず、
--- 単純な線形走査で十分と判断している。
---@param prefix string
---@param has_okuri boolean
---@param max_results integer
---@return string[] readings 前方一致した読み（昇順ソート済み）
function M.lookup_prefix(prefix, has_okuri, max_results)
  if prefix == "" then
    return {}
  end
  local section = has_okuri and data.okuri_ari or data.okuri_nasi
  local result = {}
  for reading in pairs(section) do
    if reading:sub(1, #prefix) == prefix then
      result[#result + 1] = reading
      if #result >= max_results then
        break
      end
    end
  end
  table.sort(result)
  return result
end

--- 選択された候補を学習する: その読みの候補一覧の先頭に移動する
--- （既に個人辞書にあれば削除してから先頭に挿入、無ければ新規挿入）。
--- M.load() でパスが設定されていなければ何もしない（個人辞書 無効時）。
---@param reading string
---@param has_okuri boolean
---@param word string
---@param annotation string|nil
function M.record_selection(reading, has_okuri, word, annotation)
  if not path then
    return
  end

  local section = has_okuri and data.okuri_ari or data.okuri_nasi
  local existing = section[reading] or {}

  local filtered = {}
  for _, c in ipairs(existing) do
    if c.word ~= word then
      table.insert(filtered, c)
    end
  end
  table.insert(filtered, 1, { word = word, annotation = annotation })
  section[reading] = filtered

  -- 【重要】以前はここで毎回 M.save() を同期的に呼んでいた（ファイル冒頭の
  -- コメント参照）。確定のたびに個人辞書全体をディスクへ書きに行くのは
  -- 長文入力ほど重くなるため、デバウンスしたまとめ書きに変更している。
  schedule_save()
end

--- 保留中のデバウンス保存があれば、即座に（同期的に）書き出す。無ければ
--- 何もしない。通常はテストや、明示的に「今すぐ確実に書き出したい」
--- 場面でのみ使う想定（Neovim終了時の取りこぼし防止は VimLeavePre で
--- 自動的に行われるため、通常の利用でこれを直接呼ぶ必要は無い）。
function M.flush()
  flush_pending_save()
end

--- 現在の個人辞書の内容をファイルに書き出す。M.load() でパスが
--- 設定されていなければ何もしない。
function M.save()
  if not path then
    return
  end

  -- 親ディレクトリが無ければ作る（skkeleton の慣習である
  -- ~/.local/share/skk/ は多くの環境でまだ存在しないため）。
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local text = jisyo_parser.serialize(data)
  local f, err = io.open(path, "w")
  if not f then
    vim.notify("skk.nvim: 個人辞書の保存に失敗しました (" .. tostring(err) .. ")", vim.log.levels.WARN)
    return
  end
  f:write(text)
  f:close()
end

return M
