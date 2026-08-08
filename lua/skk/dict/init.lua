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

--- パース済みの辞書データを登録する（jisyo_parser.parse() の戻り値）。
--- 後続フェーズでは複数の辞書ソースをマージしたものをここに渡す想定。
---@param dict table
function M.set_dict(dict)
  loaded_dict = dict
end

---@return boolean
function M.is_ready()
  return loaded_dict ~= nil
end

--- 辞書ファイルを、Neovimの起動や編集操作をブロックしないように読み込んで
--- M.set_dict() まで行う。
---
--- SKK-JISYO.L（数MB）程度なら M.load()（同期）でも体感できるほどの遅延は
--- 無いが、SKK-JISYO.LL のような大きな辞書（十数MB・数十万行）を
--- 同期パースすると Neovim が数秒単位でフリーズする（実測あり）。
--- この関数は (1) ファイル読み込み・文字コード変換を vim.schedule() で
--- 起動完了後まで遅延させ、(2) パース本体は jisyo_parser.parse_async() で
--- チャンクに分割してイベントループに譲歩させながら進めることで、
--- 大きな辞書でもエディタの操作感を損なわない。
---@param path string
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@param on_done fun(ok: boolean, err: string|nil)|nil 完了時に呼ばれるコールバック（省略可）
---@param chunk_size integer|nil jisyo_parser.parse_async() に渡すチャンクサイズ
function M.load_dictionary_async(path, file_encoding, on_done, chunk_size)
  vim.schedule(function()
    local utf8_text, err = file_source.read_and_decode(path, file_encoding)
    if not utf8_text then
      if on_done then
        on_done(false, err)
      end
      return
    end
    jisyo_parser.parse_async(utf8_text, function(dict)
      M.set_dict(dict)
      if on_done then
        on_done(true, nil)
      end
    end, chunk_size)
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
---@param reading string 送りなしの場合は読みそのもの、送りありの場合は reading..okuri_consonant（例: "うごk"）
---@param has_okuri boolean
---@return SkkDictCandidate[] candidates 見つからなければ空配列。各要素は {word, annotation} のテーブル。
function M.lookup(reading, has_okuri)
  local personal = user_dict.lookup(reading, has_okuri)
  local main = {}
  if loaded_dict then
    local bucket = has_okuri and loaded_dict.okuri_ari or loaded_dict.okuri_nasi
    main = bucket[reading] or {}
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
