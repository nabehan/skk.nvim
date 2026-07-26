-- lua/skk/dict/jisyo_parser.lua
--
-- SKK辞書形式（SKK-JISYO）のパーサ。
--
-- 【前提】このパーサは常に UTF-8 にデコード済みのテキストを受け取る。
-- 伝統的な SKK-JISYO.L 等は EUC-JP エンコーディングが主流だが、
-- その変換は lua/skk/encoding.lua（vim.fn.iconv() のラッパー）が
-- 読み込み側で別途担当する。パーサ自体はエンコーディングに関与しない
-- ことで、vim.* に依存せず単体テストできるようにしている。
--
-- 【フォーマット】
--   ;; okuri-ari entries.       -- セクション区切り（送りあり）
--   うごk /動/                  -- reading（末尾は送り仮名の子音）+ /候補/候補/...
--   ;; okuri-nasi entries.      -- セクション区切り（送りなし）
--   かんじ /漢字/幹事;幹事さん/  -- 候補には ";" 区切りで注釈が付くことがある
--
-- ";;" で始まる行はコメント（セクション区切り以外は無視する）。

local M = {}

--- 候補文字列からアノテーション（";" 以降）を取り除く。
---@param cand string
---@return string
local function strip_annotation(cand)
  local semi = cand:find(";", 1, true)
  if semi then
    return cand:sub(1, semi - 1)
  end
  return cand
end

--- 1行をパースする。
--- 例: "かんじ /漢字/幹事/" -> reading="かんじ", candidates={"漢字","幹事"}
--- 例: "うごk /動/"         -> reading="うごk", candidates={"動"}
--- コメント行・不正な行（"/" で始まらない候補部等）は nil, nil を返す。
---@param line string
---@return string|nil reading
---@return string[]|nil candidates
local function parse_line(line)
  if line == "" or line:sub(1, 2) == ";;" then
    return nil, nil
  end

  local sp = line:find(" ", 1, true)
  if not sp then
    return nil, nil
  end

  local reading = line:sub(1, sp - 1)
  local rest = line:sub(sp + 1)

  if rest:sub(1, 1) ~= "/" then
    return nil, nil
  end

  local candidates = {}
  for cand in rest:gmatch("/([^/]+)") do
    cand = strip_annotation(cand)
    if cand ~= "" then
      table.insert(candidates, cand)
    end
  end

  if #candidates == 0 then
    return nil, nil
  end

  return reading, candidates
end

M._parse_line = parse_line -- テストから直接検証できるように公開しておく

--- 同じ reading の候補リストへ、重複を避けつつ追加でマージする。
---@param bucket table<string, string[]>
---@param reading string
---@param candidates string[]
local function merge_into(bucket, reading, candidates)
  local existing = bucket[reading]
  if not existing then
    bucket[reading] = candidates
    return
  end

  local seen = {}
  for _, c in ipairs(existing) do
    seen[c] = true
  end
  for _, c in ipairs(candidates) do
    if not seen[c] then
      table.insert(existing, c)
      seen[c] = true
    end
  end
end

--- SKK辞書のテキスト全体（UTF-8の複数行文字列）をパースする。
---@param text string
---@return { okuri_ari: table<string, string[]>, okuri_nasi: table<string, string[]> }
function M.parse(text)
  local dict = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi" -- セクションマーカーが無い辞書ファイルもあるためデフォルトを用意

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "") -- CRLF 対応

    if line == ";; okuri-ari entries." then
      section = "okuri_ari"
    elseif line == ";; okuri-nasi entries." then
      section = "okuri_nasi"
    else
      local reading, candidates = parse_line(line)
      if reading then
        merge_into(dict[section], reading, candidates)
      end
    end
  end

  return dict
end

return M
