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

--- 個人辞書ファイルを読み込む（UTF-8前提）。以降の record_selection() は
--- このパスに自動保存する。
--- ファイルがまだ存在しない場合はエラーにせず、空の状態で始める
--- （個人辞書は「まだ何も学習していない」のが正常な初期状態のため）。
---@param file_path string
function M.load(file_path)
  path = file_path
  local f = io.open(file_path, "rb")
  if not f then
    data = { okuri_ari = {}, okuri_nasi = {} }
    return
  end
  local text = f:read("*a")
  f:close()
  data = jisyo_parser.parse(text or "")
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

  M.save()
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
