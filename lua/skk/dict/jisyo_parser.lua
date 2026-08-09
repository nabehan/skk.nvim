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

---@class SkkDictCandidate
---@field word string 変換候補本体
---@field annotation string|nil 注釈（無ければ nil）。候補一覧ウィンドウでの参考表示用。

--- 候補文字列を本体とアノテーション（";" 以降）に分割する。
---@param cand string
---@return string word
---@return string|nil annotation
local function split_annotation(cand)
  local semi = cand:find(";", 1, true)
  if semi then
    local annotation = cand:sub(semi + 1)
    if annotation == "" then
      annotation = nil
    end
    return cand:sub(1, semi - 1), annotation
  end
  return cand, nil
end

--- "/候補1;注釈/候補2/..." 形式の候補部分の文字列を候補配列にパースする。
--- 重複する word は最初に見つかったものを優先し、以降は無視する
--- （merge_into() が複数行にまたがる場合に行っていたのと同じ規則。
--- 遅延パース時は複数行ぶんの生文字列を連結してからこの関数に渡すため、
--- ここで一括してdedupする）。
---@param rest string 例: "/漢字;人名用/幹事/"
---@return SkkDictCandidate[]
local function parse_candidates_string(rest)
  local candidates = {}
  local seen = {}
  for cand in rest:gmatch("/([^/]+)") do
    local word, annotation = split_annotation(cand)
    if word ~= "" and not seen[word] then
      table.insert(candidates, { word = word, annotation = annotation })
      seen[word] = true
    end
  end
  return candidates
end

M._parse_candidates_string = parse_candidates_string -- テストから直接検証できるように公開しておく

--- 1行をパースする。
--- 例: "かんじ /漢字/幹事/"       -> reading="かんじ", candidates={{word="漢字"},{word="幹事"}}
--- 例: "かんじ /漢字;木の意/"     -> candidates={{word="漢字", annotation="木の意"}}
--- 例: "うごk /動/"               -> reading="うごk", candidates={{word="動"}}
--- コメント行・不正な行（"/" で始まらない候補部等）は nil, nil を返す。
---@param line string
---@return string|nil reading
---@return SkkDictCandidate[]|nil candidates
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

  local candidates = parse_candidates_string(rest)
  if #candidates == 0 then
    return nil, nil
  end

  return reading, candidates
end

M._parse_line = parse_line -- テストから直接検証できるように公開しておく

--- 同じ reading の候補リストへ、重複（同じ word）を避けつつ追加でマージする。
--- 既に同じ word がある場合、後から来たアノテーションでは上書きしない
--- （最初に見つかった辞書エントリのアノテーションを優先する）。
---@param bucket table<string, SkkDictCandidate[]>
---@param reading string
---@param candidates SkkDictCandidate[]
local function merge_into(bucket, reading, candidates)
  local existing = bucket[reading]
  if not existing then
    bucket[reading] = candidates
    return
  end

  local seen = {}
  for _, c in ipairs(existing) do
    seen[c.word] = true
  end
  for _, c in ipairs(candidates) do
    if not seen[c.word] then
      table.insert(existing, c)
      seen[c.word] = true
    end
  end
end

--- 1行ぶんの処理（セクション判定 or parse_line+merge_into）を行う。
--- M.parse()（同期）と M.parse_async()（非同期・チャンク分割）の両方から
--- 共有される、パースループの本体1ステップぶん。
---@param dict { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> }
---@param section "okuri_ari"|"okuri_nasi"
---@param line string
---@return "okuri_ari"|"okuri_nasi" next_section
local function process_line(dict, section, line)
  line = line:gsub("\r$", "") -- CRLF 対応

  if line == ";; okuri-ari entries." then
    return "okuri_ari"
  elseif line == ";; okuri-nasi entries." then
    return "okuri_nasi"
  end

  local reading, candidates = parse_line(line)
  if reading then
    merge_into(dict[section], reading, candidates)
  end
  return section
end

--- SKK辞書のテキスト全体（UTF-8の複数行文字列）をパースする。
---@param text string
---@return { okuri_ari: table<string, SkkDictCandidate[]>, okuri_nasi: table<string, SkkDictCandidate[]> }
function M.parse(text)
  local dict = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi" -- セクションマーカーが無い辞書ファイルもあるためデフォルトを用意

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    section = process_line(dict, section, line)
  end

  return dict
end

--- 何行かに1回だけ os.clock() を確認しながら、行配列を先頭から処理する
--- 汎用ランナー。固定行数でチャンクを区切るより優れている: 実行速度
--- （LuaJIT かどうか、CPUの速さ等）に自動で適応するので、ファイルの
--- 大小によらずイベントループへ譲歩する回数（vim.schedule() の呼び出し
--- 回数）を最小限に抑えられる。
--- 【背景】固定行数（例: 2000行/チック）で区切っていたところ、実際の
--- インタラクティブなNeovim上では vim.schedule() 1回あたりのオーバー
--- ヘッドがヘッドレス環境よりずっと大きく、行数の少ない辞書
--- （SKK-JISYO.L 相当）ではチャンク化のオーバーヘッドの方が支配的に
--- なり、かえって遅くなる回帰が実際に発生した。時間予算方式なら
--- チャンク数自体が減るため、この種の環境依存のオーバーヘッドに
--- 強くなる。
---@param lines string[]
---@param process_one fun(idx: integer) 1行ぶんを処理するコールバック
---@param on_done fun()
---@param time_budget_ms number|nil 1チックあたりの目安処理時間（省略時 30ms）
local function run_chunked(lines, process_one, on_done, time_budget_ms)
  local budget_s = (time_budget_ms or 30) / 1000
  local total = #lines
  local i = 1
  local CLOCK_CHECK_INTERVAL = 500 -- os.clock() 呼び出し自体のオーバーヘッドを避けるため間引く

  local function step()
    local deadline = os.clock() + budget_s
    local since_check = 0
    while i <= total do
      process_one(i)
      i = i + 1
      since_check = since_check + 1
      if since_check >= CLOCK_CHECK_INTERVAL then
        since_check = 0
        if os.clock() >= deadline then
          break
        end
      end
    end

    if i > total then
      on_done()
    else
      vim.schedule(step)
    end
  end

  if total == 0 then
    on_done()
  else
    step()
  end
end

--- SKK辞書のテキスト全体を行配列に分割する（末尾に改行が無くても最終行を拾う）。
---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

--- M.parse() のノンブロッキング版。
--- SKK-JISYO.L や SKK-JISYO.LL のような大きな辞書（数十万行）は、
--- M.parse() で同期パースすると Neovim が数秒単位でフリーズしてしまう
--- （実測: 17MB・52万行のファイルで約3.6〜4秒。この開発環境の Lua 5.4 での
--- 計測で、実際の Neovim の LuaJIT ならもっと速い可能性が高い）。
--- この関数は time_budget_ms ぶんの処理が終わるたびに `vim.schedule()` で
--- 次のイベントループティックに続きを回すことで、パース全体をイベント
--- ループに譲歩させながら進める。
---@param text string
---@param on_done fun(dict: { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> })
---@param time_budget_ms number|nil 1チックあたりの目安処理時間（ミリ秒。省略時 30）
function M.parse_async(text, on_done, time_budget_ms)
  local dict = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi"
  local lines = split_lines(text)

  run_chunked(lines, function(idx)
    section = process_line(dict, section, lines[idx])
  end, function()
    on_done(dict)
  end, time_budget_ms)
end

--- 1行ぶんの軽量インデックス化を行う。候補文字列はパースせず、
--- reading -> 生の候補文字列（"/候補1/候補2/" 形式）だけを記録する。
--- 実際の候補パースは、そのreadingが検索されたときに初めて
--- parse_candidates_string() で行う（lua/skk/dict/init.lua 参照）。
--- 同じreadingが複数行にまたがる場合は生文字列をそのまま連結しておく
--- （connectedしても "/.../ ".."/... /" の形のまま有効な候補部分文字列に
--- なるので、parse_candidates_string() が最初に見つかったwordを優先して
--- dedupしてくれる。M.parse()のmerge_into()と同じ規則になる）。
---@param index { okuri_ari: table<string,string>, okuri_nasi: table<string,string> }
---@param section "okuri_ari"|"okuri_nasi"
---@param line string
---@return "okuri_ari"|"okuri_nasi" next_section
local function process_line_for_index(index, section, line)
  line = line:gsub("\r$", "") -- CRLF 対応

  if line == ";; okuri-ari entries." then
    return "okuri_ari"
  elseif line == ";; okuri-nasi entries." then
    return "okuri_nasi"
  end

  if line == "" or line:sub(1, 2) == ";;" then
    return section
  end

  local sp = line:find(" ", 1, true)
  if not sp then
    return section
  end

  local reading = line:sub(1, sp - 1)
  local rest = line:sub(sp + 1)
  if rest:sub(1, 1) == "/" then
    local bucket = index[section]
    bucket[reading] = (bucket[reading] or "") .. rest
  end

  return section
end

--- SKK辞書のテキスト全体を、候補文字列はパースせずに軽量インデックス化する
--- （M.parse() より高速。実測: 17MB・52万行のファイルで
--- 約1.7秒 vs フルパースの約4秒）。返り値の各エントリは生の候補文字列
--- （M._parse_candidates_string() でその場でパースする）。
---@param text string
---@return { okuri_ari: table<string,string>, okuri_nasi: table<string,string> }
function M.build_raw_index(text)
  local index = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi"

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    section = process_line_for_index(index, section, line)
  end

  return index
end

--- M.build_raw_index() のノンブロッキング版（M.parse_async() と同じ
--- 時間予算方式のチャンク分割）。
---@param text string
---@param on_done fun(index: { okuri_ari: table<string,string>, okuri_nasi: table<string,string> })
---@param time_budget_ms number|nil 1チックあたりの目安処理時間（ミリ秒。省略時 30）
function M.build_raw_index_async(text, on_done, time_budget_ms)
  local index = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi"
  local lines = split_lines(text)

  run_chunked(lines, function(idx)
    section = process_line_for_index(index, section, lines[idx])
  end, function()
    on_done(index)
  end, time_budget_ms)
end

--- M.parse() の逆演算。パース結果と同じ構造のテーブルを SKK-JISYO 形式の
--- テキストに直列化する。個人辞書（学習結果）の保存に使う。
--- reading は文字列としてソートしてから書き出す（Lua の pairs() は
--- テーブルの走査順を保証しないため、保存するたびに順序が変わって
--- 差分が無駄に大きくなるのを避ける）。
---@param dict { okuri_ari: table<string, SkkDictCandidate[]>, okuri_nasi: table<string, SkkDictCandidate[]> }
---@return string
function M.serialize(dict)
  local function section_lines(section)
    local readings = {}
    for reading in pairs(section) do
      table.insert(readings, reading)
    end
    table.sort(readings)

    local lines = {}
    for _, reading in ipairs(readings) do
      local parts = {}
      for _, c in ipairs(section[reading]) do
        if c.annotation then
          table.insert(parts, c.word .. ";" .. c.annotation)
        else
          table.insert(parts, c.word)
        end
      end
      table.insert(lines, reading .. " /" .. table.concat(parts, "/") .. "/")
    end
    return lines
  end

  local out = { ";; okuri-ari entries." }
  for _, line in ipairs(section_lines(dict.okuri_ari)) do
    table.insert(out, line)
  end
  table.insert(out, ";; okuri-nasi entries.")
  for _, line in ipairs(section_lines(dict.okuri_nasi)) do
    table.insert(out, line)
  end
  table.insert(out, "") -- 末尾改行のため

  return table.concat(out, "\n")
end

return M
