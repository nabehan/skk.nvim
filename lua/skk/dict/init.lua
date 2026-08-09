-- lua/skk/dict/init.lua
--
-- 辞書検索の公開API。
--
-- メイン辞書（単一。set_dict() で登録）に加えて、個人辞書
-- （lua/skk/dict/user_dict.lua。学習結果を保持する）を検索結果の先頭に
-- マージする。複数辞書のマージ・優先順位・SKKサーバーは今後の課題
-- （README のロードマップ参照）。

local user_dict = require("skk.dict.user_dict")
local file_source = require("skk.dict.file_source")
local jisyo_parser = require("skk.dict.jisyo_parser")

local M = {}

---@type { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> }|nil
local loaded_dict = nil

--- M.load_dictionary_async() が使う、候補文字列を遅延パースするための
--- 生インデックス（jisyo_parser.build_raw_index_async() の戻り値）。
--- 実際に検索されたreadingだけを parsed_cache にメモ化しながらパースする
--- ことで、巨大な辞書（数十万エントリ）でも起動時に全件パースせずに済む。
---@type { okuri_ari: table<string,string>, okuri_nasi: table<string,string> }|nil
local raw_index = nil
---@type { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> }
local parsed_cache = { okuri_ari = {}, okuri_nasi = {} }

--- パース済みの辞書データを登録する（jisyo_parser.parse() の戻り値）。
--- M.load_dictionary_async() で登録した辞書（raw_index）があれば、
--- こちらを呼ぶと置き換える（両方が同時に有効になることはない。
--- 常に最後に呼ばれた方が「メイン辞書」になる）。
---@param dict table
function M.set_dict(dict)
  loaded_dict = dict
  raw_index = nil
  parsed_cache = { okuri_ari = {}, okuri_nasi = {} }
end

---@return boolean
function M.is_ready()
  return loaded_dict ~= nil or raw_index ~= nil
end

--- raw_index からの遅延パース（メモ化付き）。
---@param reading string
---@param has_okuri boolean
---@return SkkDictCandidate[]
local function lookup_raw_index(reading, has_okuri)
  local section = has_okuri and "okuri_ari" or "okuri_nasi"
  local cached = parsed_cache[section][reading]
  if cached ~= nil then
    return cached
  end

  local raw = raw_index[section][reading]
  local candidates = raw and jisyo_parser._parse_candidates_string(raw) or {}
  parsed_cache[section][reading] = candidates
  return candidates
end

--- 辞書ファイルを、Neovimの起動や編集操作をブロックしないように読み込んで
--- 登録する。
---
--- SKK-JISYO.L（数MB）程度なら M.load()（同期）でも体感できるほどの遅延は
--- 無いが、SKK-JISYO.LL のような大きな辞書（十数MB・数十万行）を
--- 同期パースすると Neovim が数秒単位でフリーズする（実測あり）。
--- この関数は次の2段構えで負荷を減らす:
---   1. ファイル読み込み・文字コード変換・インデックス化を vim.schedule() で
---      起動完了後まで遅延させ、インデックス化本体
---      （jisyo_parser.build_raw_index_async()）はチャンクに分割して
---      イベントループに譲歩させながら進める（候補文字列そのものはまだ
---      パースしない。実測: 17MB・52万行で全文パースの半分以下の時間）。
---   2. 実際の候補パースは、そのreadingが検索（lookup）された瞬間に
---      初めて行い、結果をメモ化する。巨大な辞書でも実際に引かれる
---      readingは全体のごく一部なので、体感の起動負荷をさらに減らせる。
---@param path string
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@param on_done fun(ok: boolean, err: string|nil)|nil 完了時に呼ばれるコールバック（省略可）
---@param time_budget_ms number|nil jisyo_parser.build_raw_index_async() に渡す、1チックあたりの目安処理時間（ミリ秒）
function M.load_dictionary_async(path, file_encoding, on_done, time_budget_ms)
  vim.schedule(function()
    local utf8_text, err = file_source.read_and_decode(path, file_encoding)
    if not utf8_text then
      if on_done then
        on_done(false, err)
      end
      return
    end
    jisyo_parser.build_raw_index_async(utf8_text, function(index)
      loaded_dict = nil
      raw_index = index
      parsed_cache = { okuri_ari = {}, okuri_nasi = {} }
      if on_done then
        on_done(true, nil)
      end
    end, time_budget_ms)
  end)
end

--- 個人辞書ファイルを読み込み、以降 lookup()/record_selection() で使う。
--- lua/skk/init.lua の M.setup({ user_dictionary = "..." }) から呼ばれる。
---@param file_path string
function M.set_user_dict_path(file_path)
  user_dict.load(file_path)
end

--- 読みから候補を検索する。個人辞書に学習済みの候補があれば先頭に、
--- 続けてメイン辞書の候補（個人辞書と重複する word は除く）を返す。
--- メイン辞書は M.set_dict()（同期・eager）と M.load_dictionary_async()
--- （非同期・遅延パース）のどちらでも登録できるが、常に最後に呼ばれた
--- 方が有効になる（両方が同時に有効になることはない）。
---@param reading string 送りなしの場合は読みそのもの、送りありの場合は reading..okuri_consonant（例: "うごk"）
---@param has_okuri boolean
---@return SkkDictCandidate[] candidates 見つからなければ空配列。各要素は {word, annotation} のテーブル。
function M.lookup(reading, has_okuri)
  local personal = user_dict.lookup(reading, has_okuri)
  local main = {}
  if loaded_dict then
    local bucket = has_okuri and loaded_dict.okuri_ari or loaded_dict.okuri_nasi
    main = bucket[reading] or {}
  elseif raw_index then
    main = lookup_raw_index(reading, has_okuri)
  end

  if #personal == 0 then
    return main
  end

  local merged = {}
  local seen = {}
  for _, c in ipairs(personal) do
    table.insert(merged, c)
    seen[c.word] = true
  end
  for _, c in ipairs(main) do
    if not seen[c.word] then
      table.insert(merged, c)
      seen[c.word] = true
    end
  end
  return merged
end

--- 確定した候補を個人辞書に学習させる（次回そのSame読みを検索したとき
--- 先頭候補になる）。lua/skk/henkan/state.lua が ▼確定時に呼ぶ。
---@param reading string
---@param has_okuri boolean
---@param word string
---@param annotation string|nil
function M.record_selection(reading, has_okuri, word, annotation)
  user_dict.record_selection(reading, has_okuri, word, annotation)
end

return M
