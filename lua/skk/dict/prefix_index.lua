-- lua/skk/dict/prefix_index.lua
--
-- 読みをキーとするテーブル（{[reading]=...}）から、前方一致検索を
-- 効率よく行うための共通ヘルパー。dict/init.lua の各辞書ソース
-- （make_eager_source/make_raw_index_source）が使う。
--
-- 【なぜ必要か】blink.cmp ネイティブソースで「▽ 見出し語入力中から
-- 前方一致の候補をリアルタイムに出す」機能（skkeleton 同等）を実現する
-- には、キー入力のたびに辞書を前方一致検索する必要がある。SKK-JISYO.L
-- 相当の辞書は数十万エントリになりうるため、毎回全キーを線形走査するのは
-- 避けたい。キー一覧を1回だけソートしておけば、以降は二分探索で
-- 「prefixで始まるキーの範囲」を O(log n + 該当件数) で求められる。
--
-- 個人辞書（user_dict.lua）は通常小規模（学習した語のみ）なので、
-- こちらは線形走査で十分と判断し、この仕組みは使っていない。

local M = {}

--- テーブルのキー一覧を昇順ソートして返す。
---@param tbl table<string, any>
---@return string[] sorted_keys
function M.build_sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

--- ソート済み配列 sorted_keys の中から、prefix 以上になる最初の
--- インデックスを二分探索で求める（配列の範囲外なら #sorted_keys + 1）。
---@param sorted_keys string[]
---@param prefix string
---@return integer index
local function lower_bound(sorted_keys, prefix)
  local lo, hi = 1, #sorted_keys + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if sorted_keys[mid] < prefix then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

--- sorted_keys（M.build_sorted_keys() の戻り値）のうち、prefix で
--- 前方一致するものを昇順で返す。
---@param sorted_keys string[] 昇順ソート済みであること（呼び出し側の責任）
---@param prefix string 空文字列なら常に空配列を返す（辞書全件を返すような
---  誤用を防ぐため）
---@param max_results integer|nil 指定した件数に達したら打ち切る
---@return string[] matching_keys
function M.prefix_range(sorted_keys, prefix, max_results)
  if prefix == "" then
    return {}
  end
  local result = {}
  local idx = lower_bound(sorted_keys, prefix)
  for i = idx, #sorted_keys do
    local k = sorted_keys[i]
    if k:sub(1, #prefix) ~= prefix then
      break
    end
    result[#result + 1] = k
    if max_results and #result >= max_results then
      break
    end
  end
  return result
end

return M
