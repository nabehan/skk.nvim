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
    convert("zyoshiki", "じょしき")
  end)
end)
