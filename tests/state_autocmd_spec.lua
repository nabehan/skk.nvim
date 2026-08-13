-- tests/state_autocmd_spec.lua
--
-- henkan/state.lua が発火する User autocmd ("SkkHenkanChanged") の検証。
-- blink.cmp ネイティブソース等が、▽/▼ の状態変化をこの autocmd 経由で
-- 検知する（skkeleton の "skkeleton-mode-changed"/"skkeleton-handled" 相当）。
--
-- 【注意】これは実際の vim.api.nvim_exec_autocmds()/nvim_create_autocmd() が
-- 必要なため、state_spec.lua のように大部分をモックした vim.api では
-- 検証できない。ここでは実際の（モックしていない）headless Neovim 上で、
-- henkan/state.lua を直接操作して確認する
-- （tests/skkserv_spec.lua がフェイクサーバーとの実通信を検証するのと
-- 同じ立ち位置）。

local state = require("skk.henkan.state")
local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")

local function reset()
  state.setup({ candidate_window_threshold = 1 })
  if state.is_active() then
    state.cancel()
  end
  dict.set_dict(parser.parse("かんじ /漢字/幹事/"))
  dict.set_user_dict_path(vim.fn.tempname())
  vim.cmd("enew") -- 毎回新しいスクラッチバッファにする
end

--- fn() の実行中に発火した SkkHenkanChanged イベントの data を全て集めて返す。
---@param fn fun()
---@return table[] events
local function capture_events(fn)
  local events = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "SkkHenkanChanged",
    callback = function(ev)
      table.insert(events, ev.data)
    end,
  })
  fn()
  vim.api.nvim_del_autocmd(id)
  return events
end

describe("henkan/state: SkkHenkanChanged User autocmd", function()
  before_each(reset)

  it(
    "▽ 開始直後は phase='midashi'、reading は未確定分を含まず空文字列で通知される",
    function()
      -- "k" は子音のみでまだ確定していないローマ字断片なので、
      -- session.reading（確定済み部分のみ）には含まれない
      -- （画面表示用の midashi_display() が別途 reading_pending() と
      -- 連結して見せている。上のコメント参照）。
      local events = capture_events(function()
        state.start_midashi("hira", "k")
      end)
      assert.are.equal(1, #events)
      assert.are.equal("midashi", events[1].phase)
      assert.are.equal("", events[1].reading)
    end
  )

  it("読み入力のたびに reading が更新されて通知される", function()
    state.start_midashi("hira", "k")
    local events = capture_events(function()
      state.input("a")
    end)
    assert.are.equal(1, #events)
    assert.are.equal("midashi", events[1].phase)
    assert.are.equal("か", events[1].reading)
  end)

  it("▼ 遷移（検索）で phase='select' と has_okuri=false が通知される", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    local events = capture_events(function()
      state.space()
    end)
    assert.is_true(#events >= 1)
    local last = events[#events]
    assert.are.equal("select", last.phase)
    assert.are.equal(false, last.has_okuri)
    assert.are.equal("かんじ", last.reading)
  end)

  it("確定すると phase='idle' が通知される（reading 等は付かない）", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space()
    local events = capture_events(function()
      state.confirm()
    end)
    assert.are.equal(1, #events)
    assert.are.equal("idle", events[1].phase)
    assert.is_nil(events[1].reading)
  end)

  it("キャンセルすると phase='idle' が通知される", function()
    state.start_midashi("hira", "k")
    local events = capture_events(function()
      state.cancel()
    end)
    assert.are.equal(1, #events)
    assert.are.equal("idle", events[1].phase)
  end)

  it("abbrev 開始（\"/\"）でも phase='abbrev' が通知される", function()
    local events = capture_events(function()
      state.start_abbrev("hira")
    end)
    assert.are.equal(1, #events)
    assert.are.equal("abbrev", events[1].phase)
  end)
end)
