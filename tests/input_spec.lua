-- tests/input_spec.lua
--
-- plenary.nvim の busted 互換テストランナーで実行する想定。
--   :PlenaryBustedFile tests/input_spec.lua
-- もしくは Makefile 経由で
--   nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local Context = require("skk.context")
local Input = require("skk.input")

---@param input string
---@param expect_fixed string
---@param expect_buffer string|nil
local function convert(input, expect_fixed, expect_buffer)
  local context = Context.new()
  for char in input:gmatch(".") do
    Input.kanaInput(context, char)
  end
  assert.are.equal(expect_fixed, context.fixed)
  assert.are.equal(expect_buffer or "", context.buffer)
end

describe("kana conversion (basic)", function()
  it("single mora", function()
    convert("ka", "か")
  end)

  it("multiple morae without pending buffer", function()
    convert("ohayou", "おはよう")
  end)

  it("multiple morae with pending buffer along the way (n)", function()
    convert("amenbo", "あめんぼ")
  end)
end)

describe("kana conversion (symbols)", function()
  -- capture.lua の is_target_key が %l（英小文字）しか対象にしておらず、
  -- kana_table.lua に定義済みのこれらの記号がキャプチャ層でフィルタされて
  -- 変換まで届かない不具合があった。変換エンジン自体は最初から正しかった
  -- ことを確認するための回帰テスト。
  it("long vowel mark, period, comma", function()
    convert("-", "ー")
    convert(".", "。")
    convert(",", "、")
    convert("[", "「")
    convert("]", "」")
  end)

  it("symbol mixed with regular morae", function()
    convert("ka-", "かー")
  end)

  it("z + symbol -> 全角記号", function()
    convert("z(", "（")
    convert("z)", "）")
    convert("z ", "　")
  end)

  it("単独の ( ) スペースは半角のまま素通しする", function()
    -- capture.lua で "(" ")" " " を EXTRA_TARGET_CHARS に加えた際、
    -- z( / z) / z<space> を拾えるようにするための副作用で、単独の
    -- "(" ")" " " まで「変換表にもprefixにも該当しない未対応の文字」
    -- として誤って破棄されないよう、kana_table.lua に素通し用の
    -- 恒等変換 (identity mapping) を用意している。
    convert("(", "(")
    convert(")", ")")
    convert(" ", " ")
  end)
end)

describe("kana conversion (small kana / 捨て仮名)", function()
  it("x + vowel produces small ぁぃぅぇぉ", function()
    convert("xa", "ぁ")
    convert("xi", "ぃ")
    convert("xu", "ぅ")
    convert("xe", "ぇ")
    convert("xo", "ぉ")
  end)

  it("x + ya/yu/yo produces small ゃゅょ", function()
    convert("xya", "ゃ")
    convert("xyu", "ゅ")
    convert("xyo", "ょ")
  end)

  it("xtu produces small っ directly (促音の明示指定)", function()
    convert("xtu", "っ")
  end)

  it("combines with regular morae", function()
    -- xtu を追加する前は "xtu" がテーブルに無く、誤入力からの回復ルールで
    -- x が捨てられて "tu" -> "つ" になっていた（きぃつ）。
    -- xtu が明示的に「っ」に変換されるようになったので、期待値も変わる。
    convert("kixixtu", "きぃっ")
  end)
end)

describe("kana conversion (sokuon / っ)", function()
  it("doubled consonant produces っ", function()
    convert("kka", "っか")
  end)

  it("っ appears mid-word", function()
    convert("gakkou", "がっこう")
    convert("sassoku", "さっそく")
    convert("chotto", "ちょっと")
  end)
end)

describe("kana conversion (ん)", function()
  it("explicit nn confirms ん", function()
    convert("konnnichiha", "こんにちは")
    convert("nihonn", "にほん")
  end)

  it("n followed by a non-vowel/non-y consonant confirms ん and re-processes", function()
    convert("kanji", "かんじ")
  end)

  it("a trailing single n is genuinely ambiguous and stays buffered", function()
    -- 実際の SKK でも、末尾の n は次の入力（もう一つの n や区切り文字）が
    -- 来るまで「な行」なのか「ん」なのか確定できない。これは仕様であり、
    -- バグではない。
    convert("nihon", "にほ", "n")
    convert("jishin", "じし", "n")
  end)
end)

describe("kana conversion (youon / 拗音)", function()
  it("k/g/n/h/b/p/m/r/d row + ya/yu/yo", function()
    convert("kyou", "きょう")
    convert("gyakusetsu", "ぎゃくせつ")
    convert("ryokou", "りょこう")
    convert("byouin", "びょうい", "n")
  end)

  it("sh/ch/j alternate spellings", function()
    convert("shukudai", "しゅくだい")
    convert("tyokusetsu", "ちょくせつ")
    convert("jyoushiki", "じょうしき")
    convert("joushiki", "じょうしき")
  end)
end)
