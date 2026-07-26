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

-- 拗音（きゃ・きぃ・きゅ・きぇ・きょ 等）のうち、単一子音 + "ya/yi/yu/ye/yo" で作れるもの。
-- 例: add_youon("k", "きゃ", "きぃ", "きゅ", "きぇ", "きょ") -> "kya"/"kyi"/"kyu"/"kye"/"kyo"
local function add_youon(consonant, kya, kyi, kyu, kye, kyo)
  M[consonant .. "ya"] = kya
  M[consonant .. "yi"] = kyi
  M[consonant .. "yu"] = kyu
  M[consonant .. "ye"] = kye
  M[consonant .. "yo"] = kyo
end

-- 拗音のうち、2文字の別綴りマーカー（sh/sy/ch/ty/zy 等）+ "a/u/e/o" で作るもの。
-- 例: add_youon_aueo("sh", "しゃ", "しゅ", "しぇ", "しょ") -> "sha"/"shu"/"she"/"sho"
local function add_youon_aueo(base, a, u, e, o)
  M[base .. "a"] = a
  M[base .. "u"] = u
  M[base .. "e"] = e
  M[base .. "o"] = o
end

-- か行
add_row("k", { "か", "き", "く", "け", "こ" })
add_youon("k", "きゃ", "きぃ", "きゅ", "きぇ", "きょ")

-- が行
add_row("g", { "が", "ぎ", "ぐ", "げ", "ご" })
add_youon("g", "ぎゃ", "ぎぃ", "ぎゅ", "ぎぇ", "ぎょ")

-- さ行（si/shi どちらも受け付ける）
add_row("s", { "さ", "し", "す", "せ", "そ" })
add_youon("s", "しゃ", "しぃ", "しゅ", "しぇ", "しょ")
M["shi"] = "し"
add_youon_aueo("sh", "しゃ", "しゅ", "しぇ", "しょ")

-- ざ行（zi/ji どちらも受け付ける）
add_row("z", { "ざ", "じ", "ず", "ぜ", "ぞ" })
add_youon("z", "じゃ", "じぃ", "じゅ", "じぇ", "じょ")
add_youon("j", "じゃ", "じぃ", "じゅ", "じぇ", "じょ")
M["ji"] = "じ"
add_youon_aueo("j", "じゃ", "じゅ", "じぇ", "じょ")

-- た行（ti/chi, tu/tsu どちらも受け付ける）
add_row("t", { "た", "ち", "つ", "て", "と" })
add_youon("t", "ちゃ", "ちぃ", "ちゅ", "ちぇ", "ちょ")
M["tsu"] = "つ"
M["chi"] = "ち"
add_youon_aueo("ch", "ちゃ", "ちゅ", "ちぇ", "ちょ")

-- だ行
add_row("d", { "だ", "ぢ", "づ", "で", "ど" })
add_youon("d", "ぢゃ", "ぢぃ", "ぢゅ", "ぢぇ", "ぢょ")

-- な行
add_row("n", { "な", "に", "ぬ", "ね", "の" })
add_youon("n", "にゃ", "にぃ", "にゅ", "にぇ", "にょ")

-- は行（hu/fu どちらも受け付ける）
add_row("h", { "は", "ひ", "ふ", "へ", "ほ" })
add_youon("h", "ひゃ", "ひぃ", "ひゅ", "ひぇ", "ひょ")
M["fa"] = "ふぁ"
M["fi"] = "ふぃ"
M["fu"] = "ふ"
M["fe"] = "ふぇ"
M["fo"] = "ふぉ"

-- ば行
add_row("b", { "ば", "び", "ぶ", "べ", "ぼ" })
add_youon("b", "びゃ", "びぃ", "びゅ", "びぇ", "びょ")

-- ぱ行
add_row("p", { "ぱ", "ぴ", "ぷ", "ぺ", "ぽ" })
add_youon("p", "ぴゃ", "ぴぃ", "ぴゅ", "ぴぇ", "ぴょ")

-- ま行
add_row("m", { "ま", "み", "む", "め", "も" })
add_youon("m", "みゃ", "みぃ", "みゅ", "みぇ", "みょ")

-- や行
M["ya"] = "や"
M["yu"] = "ゆ"
M["ye"] = "いぇ"
M["yo"] = "よ"

-- ら行
add_row("r", { "ら", "り", "る", "れ", "ろ" })
add_youon("r", "りゃ", "りぃ", "りゅ", "りぇ", "りょ")

-- わ行（wu は使わず「う」を使うのが一般的なため含めない）
M["wa"] = "わ"
M["wi"] = "うぃ"
M["we"] = "うぇ"
M["wo"] = "を"

-- ゔ行(v + 母音)
add_row("v", { "ゔぁ", "ゔぃ", "ゔ", "ゔぇ", "ゔぉ" })

-- 小文字かな
M["xa"] = "ぁ"
M["xi"] = "ぃ"
M["xu"] = "ぅ"
M["xe"] = "ぇ"
M["xo"] = "ぉ"
M["xya"] = "ゃ"
M["xyu"] = "ゅ"
M["xyo"] = "ょ"
M["xtu"] = "っ"

-- 記号
M["-"] = "ー"
M["."] = "。"
M[","] = "、"
M["["] = "「"
M["]"] = "」"

-- 単独で打ったときはそのまま半角として扱う記号
-- （下の z( / z) / z<space> を capture.lua でキャプチャ対象にするために
-- EXTRA_TARGET_CHARS へ追加する必要があるが、それだけだと "z" を経由
-- しない単独の "(" ")" " " が「変換表にもprefixにも該当しない未対応の
-- 文字」として誤って破棄されてしまう。それを防ぐための素通し用エントリ。）
M["("] = "("
M[")"] = ")"
M[" "] = " "

-- z + 記号: 全角記号への変換（多くの日本語IMEにある慣習的な入力方法）
M["z("] = "（"
M["z)"] = "）"
M["z "] = "　"

return M
