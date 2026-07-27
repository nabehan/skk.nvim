-- lua/skk/dict/init.lua
--
-- 辞書検索の公開API。
--
-- 【phase 3 時点のスコープ】単一の辞書データ（jisyo_parser.parse() の
-- 戻り値）を保持して検索できる、最小限の実装。複数辞書のマージ・
-- 優先順位・SKKサーバー・ユーザー辞書は後続フェーズ（実装順序6, 7, 8）
-- で追加する。

local M = {}

---@type { okuri_ari: table<string,string[]>, okuri_nasi: table<string,string[]> }|nil
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

--- 読みから候補を検索する。
---@param reading string 送りなしの場合は読みそのもの、送りありの場合は reading..okuri_consonant（例: "うごk"）
---@param has_okuri boolean
---@return string[] candidates 見つからなければ空配列
function M.lookup(reading, has_okuri)
  if not loaded_dict then
    return {}
  end
  local bucket = has_okuri and loaded_dict.okuri_ari or loaded_dict.okuri_nasi
  return bucket[reading] or {}
end

return M
