-- lua/skk/dict/init.lua
--
-- 辞書検索の公開API。
--
-- 複数の辞書ソース（sources、優先順位付きの配列）と、個人辞書
-- （lua/skk/dict/user_dict.lua。学習結果を保持する）、SKKサーバー
-- （lua/skk/dict/skkserv.lua）を組み合わせて検索する。
--
-- マージの優先順位: 個人辞書 > SKKサーバー（設定されていれば） >
-- ローカル辞書ソース（登録順）。word が重複する候補は、先に見つかった
-- （優先順位が高い）ものだけを残す。

local user_dict = require("skk.dict.user_dict")
local file_source = require("skk.dict.file_source")
local jisyo_parser = require("skk.dict.jisyo_parser")
local skkserv = require("skk.dict.skkserv")

local M = {}

---@class SkkDictSourceHandle
---@field name string
---@field lookup fun(reading: string, has_okuri: boolean): SkkDictCandidate[]

---@type SkkDictSourceHandle[]
local sources = {}

--- 既にパース済みの辞書データ（jisyo_parser.parse() の戻り値）をそのまま
--- 検索するソースを作る。
---@param name string
---@param dict { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> }
---@return SkkDictSourceHandle
local function make_eager_source(name, dict)
  return {
    name = name,
    lookup = function(reading, has_okuri)
      local bucket = has_okuri and dict.okuri_ari or dict.okuri_nasi
      return bucket[reading] or {}
    end,
  }
end

--- 候補文字列を遅延パースする生インデックス
--- （jisyo_parser.build_raw_index_async() の戻り値）を検索するソースを
--- 作る。実際に検索されたreadingだけをこのソース専用のキャッシュに
--- メモ化しながらパースすることで、巨大な辞書（数十万エントリ）でも
--- 起動時に全件パースせずに済む。
---@param name string
---@param index { okuri_ari: table<string,string>, okuri_nasi: table<string,string> }
---@return SkkDictSourceHandle
local function make_raw_index_source(name, index)
  local cache = { okuri_ari = {}, okuri_nasi = {} }
  return {
    name = name,
    lookup = function(reading, has_okuri)
      local section = has_okuri and "okuri_ari" or "okuri_nasi"
      local cached = cache[section][reading]
      if cached ~= nil then
        return cached
      end
      local raw = index[section][reading]
      local candidates = raw and jisyo_parser._parse_candidates_string(raw) or {}
      cache[section][reading] = candidates
      return candidates
    end,
  }
end

--- 登録済みのローカル辞書ソースをすべて削除する（個人辞書・SKKサーバーの
--- 設定はそのまま維持される）。
function M.clear_dicts()
  sources = {}
end

--- パース済みの辞書データを、唯一のローカル辞書ソースとして登録する
--- （既存のソースは全て置き換わる）。複数辞書を併用したい場合は
--- M.add_dict() を使う。
---@param dict table
function M.set_dict(dict)
  sources = { make_eager_source("main", dict) }
end

--- パース済みの辞書データを、既存のソースに追加する形で登録する
--- （優先順位は登録順。先に追加したものが優先される）。
---@param dict table
---@param name string|nil ソース名（省略時は自動採番）
function M.add_dict(dict, name)
  table.insert(sources, make_eager_source(name or ("dict" .. (#sources + 1)), dict))
end

---@return boolean
function M.is_ready()
  return #sources > 0
end

--- 辞書ファイルを非同期・遅延パースで読み込む共通の下ごしらえ。
--- ファイル読み込み・文字コード変換を vim.schedule() で遅延させ、
--- インデックス化本体を jisyo_parser.build_raw_index_async() に任せる。
---@param path string
---@param file_encoding string|nil
---@param time_budget_ms number|nil
---@param on_index fun(index: table) 生インデックスができたら呼ばれる
---@param on_err fun(err: string) 失敗したら呼ばれる
local function load_index_async(path, file_encoding, time_budget_ms, on_index, on_err)
  vim.schedule(function()
    local utf8_text, err = file_source.read_and_decode(path, file_encoding)
    if not utf8_text then
      on_err(err)
      return
    end
    jisyo_parser.build_raw_index_async(utf8_text, on_index, time_budget_ms)
  end)
end

--- 辞書ファイルを、Neovimの起動や編集操作をブロックしないように読み込んで
--- 唯一のローカル辞書ソースとして登録する（既存のソースは全て置き換わる）。
--- 複数辞書を併用したい場合は M.add_dictionary_async() を使う。
---
--- SKK-JISYO.L（数MB）程度なら M.load()（同期）でも体感できるほどの遅延は
--- 無いが、SKK-JISYO.LL のような大きな辞書（十数MB・数十万行）を
--- 同期パースすると Neovim が数秒単位でフリーズする（実測あり）。
--- この関数は次の2段構えで負荷を減らす:
---   1. ファイル読み込み・文字コード変換・インデックス化を vim.schedule() で
---      起動完了後まで遅延させ、インデックス化本体
---      （jisyo_parser.build_raw_index_async()）は一定の時間予算ごとに
---      イベントループに譲歩させながら進める（候補文字列そのものはまだ
---      パースしない）。
---   2. 実際の候補パースは、そのreadingが検索（lookup）された瞬間に
---      初めて行い、結果をメモ化する。巨大な辞書でも実際に引かれる
---      readingは全体のごく一部なので、体感の起動負荷をさらに減らせる。
---@param path string
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@param on_done fun(ok: boolean, err: string|nil)|nil 完了時に呼ばれるコールバック（省略可）
---@param time_budget_ms number|nil jisyo_parser.build_raw_index_async() に渡す、1チックあたりの目安処理時間（ミリ秒）
function M.load_dictionary_async(path, file_encoding, on_done, time_budget_ms)
  load_index_async(path, file_encoding, time_budget_ms, function(index)
    sources = { make_raw_index_source("main", index) }
    if on_done then
      on_done(true, nil)
    end
  end, function(err)
    if on_done then
      on_done(false, err)
    end
  end)
end

--- 辞書ファイルを非同期・遅延パースで読み込み、既存のソースに追加する形で
--- 登録する（優先順位は登録順）。詳しい非同期化の説明は
--- M.load_dictionary_async() のコメントを参照。
---@param path string
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@param on_done fun(ok: boolean, err: string|nil)|nil 完了時に呼ばれるコールバック（省略可）
---@param time_budget_ms number|nil jisyo_parser.build_raw_index_async() に渡す、1チックあたりの目安処理時間（ミリ秒）
---@param name string|nil ソース名（省略時はファイルパス）
function M.add_dictionary_async(path, file_encoding, on_done, time_budget_ms, name)
  load_index_async(path, file_encoding, time_budget_ms, function(index)
    table.insert(sources, make_raw_index_source(name or path, index))
    if on_done then
      on_done(true, nil)
    end
  end, function(err)
    if on_done then
      on_done(false, err)
    end
  end)
end

--- SKKサーバー（skkserv/dbskkd-cdb/yaskkserv2 等）への接続を設定する。
--- 個人辞書の次、ローカル辞書ソースより先にマージされる（skkeleton 等の
--- 一般的な運用に合わせた優先順位）。
--- nil を渡すと無効化する。
---@param opts { host: string, port: integer?, encoding: string?, timeout_ms: integer?, debug: boolean? }|nil
function M.set_skkserv(opts)
  skkserv.setup(opts)
end

--- SKKサーバーのバージョン文字列を取得する（疎通確認用）。
--- lua/skk/dict/skkserv.lua の M.get_version() を参照。
---@return string|nil
function M.skkserv_version()
  return skkserv.get_version()
end

--- 直近の SKKサーバー通信の結果（診断用）。
--- "ok" | "not_configured" | "connect_failed" | "timeout" | "error"
---@return string
function M.skkserv_status()
  return skkserv.last_status()
end

--- 個人辞書ファイルを読み込み、以降 lookup()/record_selection() で使う。
--- lua/skk/init.lua の M.setup({ user_dictionary = "..." }) から呼ばれる。
---@param file_path string
function M.set_user_dict_path(file_path)
  user_dict.load(file_path)
end

--- word が重複する候補を除きながら、from の候補を into へ追加する。
---@param into SkkDictCandidate[]
---@param seen table<string, boolean>
---@param from SkkDictCandidate[]
local function merge_into_result(into, seen, from)
  for _, c in ipairs(from) do
    if not seen[c.word] then
      table.insert(into, c)
      seen[c.word] = true
    end
  end
end

--- 読みから候補を検索する。マージの優先順位は
--- 個人辞書 > SKKサーバー（設定時） > ローカル辞書ソース（登録順）。
--- word が重複する候補は、優先順位が高い方だけを残す。
---@param reading string 送りなしの場合は読みそのもの、送りありの場合は reading..okuri_consonant（例: "うごk"）
---@param has_okuri boolean
---@return SkkDictCandidate[] candidates 見つからなければ空配列。各要素は {word, annotation} のテーブル。
function M.lookup(reading, has_okuri)
  local merged = {}
  local seen = {}

  merge_into_result(merged, seen, user_dict.lookup(reading, has_okuri))

  if skkserv.is_enabled() then
    merge_into_result(merged, seen, skkserv.lookup(reading, has_okuri))
  end

  for _, source in ipairs(sources) do
    merge_into_result(merged, seen, source.lookup(reading, has_okuri))
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
