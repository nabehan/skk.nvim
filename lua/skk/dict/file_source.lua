-- lua/skk/dict/file_source.lua
--
-- 辞書ファイルを読み込み、必要ならエンコーディング変換してからパースする。
--
-- 【phase 3 時点のスコープ】同期読み込み（io.open/io.read）で実装する。
-- 起動時の非同期化は、実際に大きな辞書でカクつきが問題になってから
-- 対応する、という段階的アプローチで合意済み（vim.uv.new_work 等は
-- ワーカー関数がクロージャを持てない等の制約があり後回しにする）。

local encoding = require("skk.encoding")
local parser = require("skk.dict.jisyo_parser")

local M = {}

--- 辞書ファイルを読み込んでパースする。
---@param path string ファイルパス
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"。
---  伝統的な SKK-JISYO.L 等は euc-jp が主流）
---@return table|nil dict パース結果（jisyo_parser.parse() の戻り値）。
---  読み込み・変換に失敗したら nil
---@return string|nil err 失敗時のエラーメッセージ
function M.load(path, file_encoding)
  file_encoding = file_encoding or "euc-jp"

  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "辞書ファイルを開けませんでした: " .. path .. " (" .. tostring(open_err) .. ")"
  end

  local raw = f:read("*a")
  f:close()

  if raw == nil then
    return nil, "辞書ファイルの読み込みに失敗しました: " .. path
  end

  local utf8_text = encoding.to_utf8(raw, file_encoding)
  if not utf8_text then
    return nil, "文字コード変換に失敗しました: " .. path .. " (" .. file_encoding .. " -> utf-8)"
  end

  return parser.parse(utf8_text), nil
end

return M
