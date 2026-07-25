-- tests/capture_integration_spec.lua
--
-- capture.lua の中核ロジック（モードに応じた変換のディスパッチ）を、
-- vim.* API に依存しない形で再現して検証する。
--
-- 実際のバッファ書き換え（vim.on_key 経由の nvim_buf_set_text 等）自体は
-- plenary/nvim でしか検証できないため、ここでは「どのテキストが最終的に
-- 挿入されるべきか」というロジックレベルの確認にとどめる。
-- ロジックは lua/skk/capture.lua の on_key と同じ部品
-- (Context / Input / kana_util / mode) を使って組み立てている。

local Context = require("skk.context")
local Input = require("skk.input")
local kana_util = require("skk.kana_util")
local mode_util = require("skk.mode")

local RENDERERS = {
  hira = function(s)
    return s
  end,
  kata = kana_util.to_katakana,
}

--- lua/skk/capture.lua の on_key ロジックを、実際のバッファ操作なしで再現する。
---@param mode SkkMode 開始モード
---@param input string 打鍵列（"l"/"q"/"L" はモード切替キーとして解釈する）
---@return string display 最終的にバッファへ反映されるべきテキスト
---@return SkkMode mode 最終モード
local function simulate(mode, input)
  local context = Context.new()
  context.mode = mode
  local out = {}

  for key in input:gmatch(".") do
    if context.mode == "ascii" then
      -- capture.lua の on_key は ascii モードでは何もせず、
      -- キーがそのまま（変換されずに）バッファへ入る。
      table.insert(out, key)
    elseif context.mode == "zenei" then
      table.insert(out, kana_util.to_zenkaku_char(key))
    else
      local target
      if context.buffer == "" then
        target = mode_util.char_transition(key, context.mode)
      end
      if target then
        context.mode = target
      else
        Input.kanaInput(context, key)
        local confirmed = context:flush()
        local render = RENDERERS[context.mode] or function(s)
          return s
        end
        table.insert(out, render(confirmed))
      end
    end
  end

  -- 末尾に残っている未確定バッファ（ローマ字のまま）も表示に含める
  table.insert(out, context.buffer)

  return table.concat(out), context.mode
end

describe("hiragana mode (default)", function()
  it("通常のローマ字入力", function()
    local display, mode = simulate("hira", "ohayou")
    assert.are.equal("おはよう", display)
    assert.are.equal("hira", mode)
  end)
end)

describe("katakana mode", function()
  it("q でひらがな -> カタカナに切り替わり、以降の入力がカタカナになる", function()
    local display, mode = simulate("hira", "qohayou")
    assert.are.equal("オハヨウ", display)
    assert.are.equal("kata", mode)
  end)

  it("カタカナモード中に q でひらがなへ戻る", function()
    local display, mode = simulate("kata", "gakkouqarigatou")
    assert.are.equal("ガッコウ" .. "ありがとう", display)
    assert.are.equal("hira", mode)
  end)
end)

describe("ascii mode (l)", function()
  it("l でひらがな -> 半角英数に切り替わり、以降は変換されない", function()
    local display, mode = simulate("hira", "ohayoulohayou")
    assert.are.equal("おはよう" .. "ohayou", display)
    assert.are.equal("ascii", mode)
  end)
end)

describe("zenei mode (L)", function()
  it("L でひらがな -> 全角英数に切り替わり、印字可能文字が全角になる", function()
    local display, mode = simulate("hira", "kanjiLhello world")
    assert.are.equal("かんじ" .. "ｈｅｌｌｏ　ｗｏｒｌｄ", display)
    assert.are.equal("zenei", mode)
  end)
end)
