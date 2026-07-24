-- lua/skk/kana_table.lua
--
-- ローマ字 → ひらがな 変換テーブル。
-- 「っ」（促音）と「ん」は規則的な変換ではなく特別扱いが必要なため、
-- ここには含めない（lua/skk/input.lua 側で処理する）。
--
-- 五十音の各行を「子音 + 母音」の組み合わせから機械的に生成することで、
-- 100行近い変換表を手書きしなくて済むようにしている。

local vowels = { "a", "i", "u", "e", "o" }
local vowel_kana = { a = "あ", i = "い", u = "う", e = "え", o = "お" }

---@type table<string, string>
local M = {}

-- 母音単体
for _, v in ipairs(vowels) do
  M[v] = vowel_kana[v]
end

-- 「子音 + あいうえお」の行を生成するヘルパー。
-- kana_row は { あ行のかな, い行のかな, う行のかな, え行のかな, お行のかな }
local function add_row(consonant, kana_row)
  for i, v in ipairs(vowels) do
    M[consonant .. v] = kana_row[i]
  end
end

-- 拗音（きゃ・きゅ・きょ 等）のうち、単一子音 + "ya/yu/yo" で作れるもの。
-- 例: add_youon("k", "きゃ", "きゅ", "きょ") -> "kya"/"kyu"/"kyo"
local function add_youon(consonant, kya, kyu, kyo)
  M[consonant .. "ya"] = kya
  M[consonant .. "yu"] = kyu
  M[consonant .. "yo"] = kyo
end

-- 拗音のうち、2文字の別綴りマーカー（sh/sy/ch/ty/zy 等）+ "a/u/o" で作るもの。
-- 例: add_youon_auo("sh", "しゃ", "しゅ", "しょ") -> "sha"/"shu"/"sho"
local function add_youon_auo(base, a, u, o)
  M[base .. "a"] = a
  M[base .. "u"] = u
  M[base .. "o"] = o
end

-- か行
add_row("k", { "か", "き", "く", "け", "こ" })
add_youon("k", "きゃ", "きゅ", "きょ")

-- が行
add_row("g", { "が", "ぎ", "ぐ", "げ", "ご" })
add_youon("g", "ぎゃ", "ぎゅ", "ぎょ")

-- さ行（si/shi どちらも受け付ける）
add_row("s", { "さ", "し", "す", "せ", "そ" })
M["shi"] = "し"
add_youon_auo("sh", "しゃ", "しゅ", "しょ")
add_youon_auo("sy", "しゃ", "しゅ", "しょ")

-- ざ行（zi/ji どちらも受け付ける）
add_row("z", { "ざ", "じ", "ず", "ぜ", "ぞ" })
M["ji"] = "じ"
add_youon_auo("j", "じゃ", "じゅ", "じょ")
add_youon_auo("zy", "じゃ", "じゅ", "じょ")

-- た行（ti/chi, tu/tsu どちらも受け付ける）
add_row("t", { "た", "ち", "つ", "て", "と" })
M["chi"] = "ち"
M["tsu"] = "つ"
add_youon_auo("ch", "ちゃ", "ちゅ", "ちょ")
add_youon_auo("ty", "ちゃ", "ちゅ", "ちょ")

-- だ行
add_row("d", { "だ", "ぢ", "づ", "で", "ど" })
add_youon("d", "ぢゃ", "ぢゅ", "ぢょ")

-- な行
add_row("n", { "な", "に", "ぬ", "ね", "の" })
add_youon("n", "にゃ", "にゅ", "にょ")

-- は行（hu/fu どちらも受け付ける）
add_row("h", { "は", "ひ", "ふ", "へ", "ほ" })
M["fu"] = "ふ"
add_youon("h", "ひゃ", "ひゅ", "ひょ")
M["fa"] = "ふぁ"
M["fi"] = "ふぃ"
M["fe"] = "ふぇ"
M["fo"] = "ふぉ"

-- ば行
add_row("b", { "ば", "び", "ぶ", "べ", "ぼ" })
add_youon("b", "びゃ", "びゅ", "びょ")

-- ぱ行
add_row("p", { "ぱ", "ぴ", "ぷ", "ぺ", "ぽ" })
add_youon("p", "ぴゃ", "ぴゅ", "ぴょ")

-- ま行
add_row("m", { "ま", "み", "む", "め", "も" })
add_youon("m", "みゃ", "みゅ", "みょ")

-- や行（yi/ye は現代仮名遣いでは使わないため省略）
M["ya"] = "や"
M["yu"] = "ゆ"
M["yo"] = "よ"

-- ら行
add_row("r", { "ら", "り", "る", "れ", "ろ" })
add_youon("r", "りゃ", "りゅ", "りょ")

-- わ行（wu は使わず「う」を使うのが一般的なため含めない）
M["wa"] = "わ"
M["wi"] = "うぃ"
M["we"] = "うぇ"
M["wo"] = "を"

-- 記号
M["-"] = "ー"
M["."] = "。"
M[","] = "、"
M["["] = "「"
M["]"] = "」"

return M
