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
local prefix_index = require("skk.dict.prefix_index")

local M = {}

---@class SkkDictSourceHandle
---@field name string
---@field lookup fun(reading: string, has_okuri: boolean): SkkDictCandidate[]
---@field prefix_lookup fun(prefix: string, has_okuri: boolean, max_results: integer): string[]

---@type SkkDictSourceHandle[]
local sources = {}

--- 既にパース済みの辞書データ（jisyo_parser.parse() の戻り値）をそのまま
--- 検索するソースを作る。
---@param name string
---@param dict { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> }
---@return SkkDictSourceHandle
local function make_eager_source(name, dict)
  -- 前方一致検索（M.lookup_prefix()）用に、キー一覧をソートして
  -- 1回だけ構築しておく。dict テーブル自体は set_dict()/add_dict() で
  -- 渡された後は書き換わらない前提（追加の辞書は別ソースとして積む）。
  local sorted_keys = {
    okuri_ari = prefix_index.build_sorted_keys(dict.okuri_ari),
    okuri_nasi = prefix_index.build_sorted_keys(dict.okuri_nasi),
  }
  return {
    name = name,
    lookup = function(reading, has_okuri)
      local bucket = has_okuri and dict.okuri_ari or dict.okuri_nasi
      return bucket[reading] or {}
    end,
    prefix_lookup = function(prefix, has_okuri, max_results)
      local keys = has_okuri and sorted_keys.okuri_ari or sorted_keys.okuri_nasi
      return prefix_index.prefix_range(keys, prefix, max_results)
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
  -- index テーブルはロード完了後は書き換わらない前提（M.lookup_prefix()
  -- 用に一度だけソート済みキー配列を構築しておく。make_eager_source と
  -- 同じ理由）。
  local sorted_keys = {
    okuri_ari = prefix_index.build_sorted_keys(index.okuri_ari),
    okuri_nasi = prefix_index.build_sorted_keys(index.okuri_nasi),
  }
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
    prefix_lookup = function(prefix, has_okuri, max_results)
      local keys = has_okuri and sorted_keys.okuri_ari or sorted_keys.okuri_nasi
      return prefix_index.prefix_range(keys, prefix, max_results)
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
--- 登録する（優先順位は M.add_dictionary_async() を*呼んだ*順。読み込みが
--- 完了した順ではない）。
---
--- 【重要】優先順位を「呼んだ順」で確定させるため、実際のパース結果が
--- まだ届いていなくても、呼ばれた時点で sources 内に「その位置」を
--- 即座に確保しておく（最初は常に空を返すプレースホルダ）。そうしないと、
--- 例えば小さい辞書（emoji等）が大きい辞書（SKK-JISYO.L）より先に
--- 読み込み終わった場合に、呼び出し順ではなく完了順が優先順位になって
--- しまう不具合になる（実際に報告のあった問題）。
---
--- 詳しい非同期化の説明は M.load_dictionary_async() のコメントを参照。
---@param path string
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@param on_done fun(ok: boolean, err: string|nil)|nil 完了時に呼ばれるコールバック（省略可）
---@param time_budget_ms number|nil jisyo_parser.build_raw_index_async() に渡す、1チックあたりの目安処理時間（ミリ秒）
---@param name string|nil ソース名（省略時はファイルパス）
function M.add_dictionary_async(path, file_encoding, on_done, time_budget_ms, name)
  local source_name = name or path
  local slot_index = #sources + 1
  sources[slot_index] = {
    name = source_name,
    lookup = function()
      return {} -- 読み込み中（またはこの後失敗した場合）は常に空
    end,
  }

  load_index_async(path, file_encoding, time_budget_ms, function(index)
    -- 読み込み中に他のソースが増減していても、確保しておいた位置に
    -- そのまま差し替える（優先順位を維持する）。
    sources[slot_index] = make_raw_index_source(source_name, index)
    if on_done then
      on_done(true, nil)
    end
  end, function(err)
    -- 失敗時はプレースホルダ（常に空を返す）のままにしておく。
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

--- 直近の接続失敗の詳細（診断用。ECONNREFUSED 等）。接続に一度も
--- 失敗していなければ nil。
---@return string|nil
function M.skkserv_last_connect_error()
  return skkserv.last_connect_error()
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
---@param skip_skkserv boolean|nil true の場合、SKKサーバーへは問い合わせない
---  （個人辞書・ローカル辞書ソースのみを検索する）。省略時 false。
---  blink.cmp のライブ補完（blink_source.lua）専用のオプション。
---  詳細は下記コメント参照。
---@return SkkDictCandidate[] candidates 見つからなければ空配列。各要素は {word, annotation} のテーブル。
function M.lookup(reading, has_okuri, skip_skkserv)
  local merged = {}
  local seen = {}

  merge_into_result(merged, seen, user_dict.lookup(reading, has_okuri))

  if not skip_skkserv and skkserv.is_enabled() then
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

--- 前方一致で読みの一覧を検索する（blink.cmp ネイティブソースの
--- ライブ補完用。`▽` 見出し語入力中に、まだ確定していない読みの
--- 前方一致候補を出す）。
---
--- 【設計】戻り値は候補（SkkDictCandidate）ではなく読み文字列の一覧に
--- とどめている。呼び出し側が各読みについて改めて M.lookup() を呼んで
--- 実際の候補一覧を得る想定（M.lookup() が既に持っている優先順位
--- マージのロジックをここで重複実装せずに済むため）。
---
--- 【実機で発見した重要な注意（v1で踏んだ地雷）】個人辞書・ローカル
--- 辞書だけなら「読みの件数だけ M.lookup() を呼ぶ」二度手間は実用上
--- 問題にならないが、SKKサーバーが有効だと話が別。まず
--- M.lookup_prefix() 自体が "4" コマンドで1回、さらに呼び出し側が
--- 読みの件数（最大 max_results 件）だけ無条件に M.lookup() を呼ぶと
--- そのたびに "1" コマンドが飛び、キー入力のたびに大量の同期TCP
--- ラウンドトリップが発生して体感できるレベルで重くなる。加えて、
--- ここで返す読み一覧は個人辞書・ローカル辞書・SKKサーバーの
--- 「和集合」なので、SKKサーバー自身の辞書には存在しない読み
--- （ローカル辞書だけが知っている読み）も混ざる。そういう読みに
--- うっかり "1" を投げると skkserv 側で notfound となり、
--- yaskkserv2 のGoogle日本語入力フォールバック（数秒単位で詰まりうる）
--- を誘発しかねない。
---
--- そのため第2戻り値 from_skkserv（reading をキーにした集合テーブル、
--- SKKサーバー自身の "4" 応答に含まれていた読みだけ true）を用意して
--- いる。呼び出し側（blink_source.lua）はこれを見て、SKKサーバーの
--- "4" 応答に実在が確認できた読みに対してだけ、件数上限つきで "1" を
--- 投げる設計にしている（notfound地雷を踏まず、往復回数も抑えられる）。
---
--- 送りありの前方一致は、まだ現実的な使い道が薄い（送り仮名の子音まで
--- 打ち終わらないと reading が定まらないため）ことと、SKKサーバーの
--- "4" コマンドが okuri-ari/okuri-nasi を区別しないプロトコルである
--- ことから、has_okuri=true の場合はそもそもローカル辞書・個人辞書のみを
--- 検索し、SKKサーバーへは問い合わせない（skip_skkserv の値に関わらず）。
---@param prefix string
---@param has_okuri boolean
---@param max_results integer
---@param skip_skkserv boolean|nil true の場合、SKKサーバーへは問い合わせない。省略時 false。
---@return string[] readings 前方一致した読み（重複無し、昇順ソート済み）
---@return table<string, boolean> from_skkserv 読み→true。SKKサーバー自身の"4"応答に含まれていた読みの集合
function M.lookup_prefix(prefix, has_okuri, max_results, skip_skkserv)
  if prefix == "" then
    return {}, {}
  end

  local seen = {}
  local result = {}
  local from_skkserv = {}

  local function add_all(readings)
    for _, reading in ipairs(readings) do
      if not seen[reading] then
        seen[reading] = true
        result[#result + 1] = reading
      end
    end
  end

  add_all(user_dict.lookup_prefix(prefix, has_okuri, max_results))

  if not has_okuri and not skip_skkserv and skkserv.is_enabled() then
    local skkserv_readings = skkserv.lookup_prefix(prefix)
    for _, reading in ipairs(skkserv_readings) do
      from_skkserv[reading] = true
    end
    add_all(skkserv_readings)
  end

  for _, source in ipairs(sources) do
    if #result >= max_results then
      break
    end
    if source.prefix_lookup then
      add_all(source.prefix_lookup(prefix, has_okuri, max_results))
    end
  end

  table.sort(result)
  if #result > max_results then
    local truncated = {}
    for i = 1, max_results do
      truncated[i] = result[i]
    end
    result = truncated
  end
  return result, from_skkserv
end

return M
