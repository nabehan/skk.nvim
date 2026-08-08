-- tests/jisyo_parser_spec.lua
--
-- lua/skk/dict/jisyo_parser.lua（SKK辞書パーサ）のテスト。
-- vim.* に依存しないので、素の Lua だけで検証できる。
--
-- 【注意】候補は {word=string, annotation=string|nil} のテーブルで返る
-- （アノテーション表示機能のため、";" 以降を切り捨てず保持している）。

local parser = require("skk.dict.jisyo_parser")

describe("jisyo_parser._parse_line", function()
  it("基本的な1行（候補1つ）", function()
    local reading, candidates = parser._parse_line("あ /亜/")
    assert.are.equal("あ", reading)
    assert.are.equal(1, #candidates)
    assert.are.equal("亜", candidates[1].word)
    assert.is_nil(candidates[1].annotation)
  end)

  it("候補が複数ある行", function()
    local reading, candidates = parser._parse_line("かんじ /漢字/幹事/監事/")
    assert.are.equal("かんじ", reading)
    assert.are.equal(3, #candidates)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("幹事", candidates[2].word)
    assert.are.equal("監事", candidates[3].word)
  end)

  it("送りありエントリ（reading の末尾に子音が付く）", function()
    local reading, candidates = parser._parse_line("うごk /動/")
    assert.are.equal("うごk", reading)
    assert.are.equal("動", candidates[1].word)
  end)

  it("候補のアノテーション（;以降）を word とは別に保持する", function()
    local reading, candidates = parser._parse_line("かんじ /漢字;人名用/幹事/")
    assert.are.equal("かんじ", reading)
    assert.are.equal("漢字", candidates[1].word)
    assert.are.equal("人名用", candidates[1].annotation)
    assert.are.equal("幹事", candidates[2].word)
    assert.is_nil(candidates[2].annotation)
  end)

  it("';' の直後が空（末尾が ';' で終わる）ならアノテーションは nil のまま", function()
    local reading, candidates = parser._parse_line("あ /亜;/")
    assert.are.equal("亜", candidates[1].word)
    assert.is_nil(candidates[1].annotation)
  end)

  it("コメント行 (;;) は nil を返す", function()
    local reading, candidates = parser._parse_line(";; okuri-ari entries.")
    assert.is_nil(reading)
    assert.is_nil(candidates)
  end)

  it("空行は nil を返す", function()
    local reading, candidates = parser._parse_line("")
    assert.is_nil(reading)
    assert.is_nil(candidates)
  end)

  it("スペースが無い不正な行は nil を返す", function()
    local reading, candidates = parser._parse_line("かんじ")
    assert.is_nil(reading)
    assert.is_nil(candidates)
  end)

  it("候補部が / で始まらない不正な行は nil を返す", function()
    local reading, candidates = parser._parse_line("かんじ 漢字")
    assert.is_nil(reading)
    assert.is_nil(candidates)
  end)
end)

describe("jisyo_parser.parse", function()
  it("okuri-nasi のみのシンプルな辞書", function()
    local text = table.concat({
      "あ /亜/阿/",
      "かんじ /漢字/幹事/",
    }, "\n")
    local dict = parser.parse(text)
    assert.are.equal("亜", dict.okuri_nasi["あ"][1].word)
    assert.are.equal("阿", dict.okuri_nasi["あ"][2].word)
    assert.are.equal("漢字", dict.okuri_nasi["かんじ"][1].word)
    assert.is_nil(dict.okuri_ari["あ"])
  end)

  it("セクション区切りで okuri-ari / okuri-nasi を正しく振り分ける", function()
    local text = table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      "あかk /赤/",
      ";; okuri-nasi entries.",
      "あい /愛/",
    }, "\n")
    local dict = parser.parse(text)
    assert.are.equal("動", dict.okuri_ari["うごk"][1].word)
    assert.are.equal("赤", dict.okuri_ari["あかk"][1].word)
    assert.are.equal("愛", dict.okuri_nasi["あい"][1].word)
    assert.is_nil(dict.okuri_nasi["うごk"])
  end)

  it("セクションマーカーが無い辞書は okuri_nasi 扱いになる", function()
    local dict = parser.parse("あ /亜/")
    assert.are.equal("亜", dict.okuri_nasi["あ"][1].word)
  end)

  it("コメント行・空行は無視される", function()
    local text = table.concat({
      ";; -*- coding: utf-8 -*-",
      "",
      "あ /亜/",
      "",
    }, "\n")
    local dict = parser.parse(text)
    assert.are.equal("亜", dict.okuri_nasi["あ"][1].word)
  end)

  it("同じ reading が複数行に分かれていてもマージされる（word の重複は除く）", function()
    local text = table.concat({
      "かんじ /漢字/幹事/",
      "かんじ /幹事/監事/", -- "幹事" は重複するので追加されないはず
    }, "\n")
    local dict = parser.parse(text)
    local cands = dict.okuri_nasi["かんじ"]
    assert.are.equal(3, #cands)
    assert.are.equal("漢字", cands[1].word)
    assert.are.equal("幹事", cands[2].word)
    assert.are.equal("監事", cands[3].word)
  end)

  it(
    "word が重複するとき、後から来たアノテーションでは上書きしない（先勝ち）",
    function()
      local text = table.concat({
        "かんじ /漢字;最初の注釈/",
        "かんじ /漢字;後からの注釈/", -- word "漢字" は重複するので追加されない
      }, "\n")
      local dict = parser.parse(text)
      local cands = dict.okuri_nasi["かんじ"]
      assert.are.equal(1, #cands)
      assert.are.equal("最初の注釈", cands[1].annotation)
    end
  )

  it("CRLF 改行でも正しくパースできる", function()
    local text = "あ /亜/\r\nかんじ /漢字/\r\n"
    local dict = parser.parse(text)
    assert.are.equal("亜", dict.okuri_nasi["あ"][1].word)
    assert.are.equal("漢字", dict.okuri_nasi["かんじ"][1].word)
  end)

  it("末尾に改行が無いファイルの最終行も拾う", function()
    local dict = parser.parse("あ /亜/")
    assert.are.equal("亜", dict.okuri_nasi["あ"][1].word)
  end)
end)

describe("jisyo_parser.serialize", function()
  it("parse() の結果を serialize() すると、同じ内容として parse() し直せる（往復）", function()
    local original_text = table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      ";; okuri-nasi entries.",
      "かんじ /漢字;人名用/幹事/",
    }, "\n")
    local dict = parser.parse(original_text)
    local serialized = parser.serialize(dict)
    local roundtrip = parser.parse(serialized)

    assert.are.equal("動", roundtrip.okuri_ari["うごk"][1].word)
    assert.are.equal("漢字", roundtrip.okuri_nasi["かんじ"][1].word)
    assert.are.equal("人名用", roundtrip.okuri_nasi["かんじ"][1].annotation)
    assert.are.equal("幹事", roundtrip.okuri_nasi["かんじ"][2].word)
  end)

  it("okuri-ari セクションが先、okuri-nasi セクションが後に出力される", function()
    local dict = { okuri_ari = { ["うごk"] = { { word = "動" } } }, okuri_nasi = { ["あ"] = { { word = "亜" } } } }
    local text = parser.serialize(dict)
    local ari_pos = text:find(";; okuri-ari entries.", 1, true)
    local nasi_pos = text:find(";; okuri-nasi entries.", 1, true)
    assert.is_true(ari_pos < nasi_pos)
  end)

  it("空の辞書は、セクションマーカーだけの空辞書として往復できる", function()
    local dict = { okuri_ari = {}, okuri_nasi = {} }
    local roundtrip = parser.parse(parser.serialize(dict))
    assert.are.same({}, roundtrip.okuri_ari)
    assert.are.same({}, roundtrip.okuri_nasi)
  end)
end)
