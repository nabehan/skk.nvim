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

  local candidates = {}
  for cand in rest:gmatch("/([^/]+)") do
    local word, annotation = split_annotation(cand)
    if word ~= "" then
      table.insert(candidates, { word = word, annotation = annotation })
    end
  end

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

--- M.parse() のノンブロッキング版。
--- SKK-JISYO.L や SKK-JISYO.LL のような大きな辞書（数十万行）は、
--- M.parse() で同期パースすると Neovim が数秒単位でフリーズしてしまう
--- （実測: 17MB・52万行のファイルで約3.6〜4秒）。この関数は
--- chunk_size 行ごとに処理を区切り、`vim.schedule()` で次のチャンクを
--- 次のイベントループティックに回すことで、パース全体をイベントループに
--- 譲歩させながら進める。1チャンクの処理時間は数十ミリ秒程度に収まり、
--- エディタの操作感を損なわない。
---@param text string
---@param on_done fun(dict: { okuri_ari: table<string,SkkDictCandidate[]>, okuri_nasi: table<string,SkkDictCandidate[]> })
---@param chunk_size integer|nil 1チックあたりに処理する行数（省略時 2000）
function M.parse_async(text, on_done, chunk_size)
  chunk_size = chunk_size or 2000

  local dict = { okuri_ari = {}, okuri_nasi = {} }
  local section = "okuri_nasi"

  -- gmatch は「途中から再開する」処理と相性が悪いので、先に行の配列に
  -- 分割しておき、添字でチャンクに区切って処理する。
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  local total = #lines
  local i = 1

  local function step()
    local stop = math.min(i + chunk_size - 1, total)
    for idx = i, stop do
      section = process_line(dict, section, lines[idx])
    end
    i = stop + 1

    if i > total then
      on_done(dict)
    else
      vim.schedule(step)
    end
  end

  if total == 0 then
    on_done(dict)
  else
    step()
  end
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
