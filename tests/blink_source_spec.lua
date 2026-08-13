-- tests/blink_source_spec.lua
--
-- lua/skk/blink_source.lua のテスト。
--
-- 【注意】blink.cmp 本体（lua/blink/cmp/types.lua 等）が rtp に無い環境
-- では動かせない。CI/開発環境で blink.cmp をクローンして rtp に追加した
-- 上で実行する想定（他のテストと違い、これは外部プラグイン依存）。
-- 無い場合はこのファイル全体を pending にする。

local has_blink_types = pcall(require, "blink.cmp.types")
if not has_blink_types then
  describe("blink_source (blink.cmp が rtp に無いためスキップ)", function()
    it("pending", function()
      pending("blink.cmp がrtpに見つからないためスキップ")
    end)
  end)
  return
end

local source_module = require("skk.blink_source")
local state = require("skk.henkan.state")
local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")

local function reset()
  state.setup({ candidate_window_threshold = 1 })
  if state.is_active() then
    state.cancel()
  end
  source_module.setup({ max_items = 50 })
  dict.set_dict(parser.parse(table.concat({
    "かんじ /漢字/幹事/",
    "かんたん /簡単/",
    "かんこう /観光/",
  }, "\n")))
  dict.set_user_dict_path(vim.fn.tempname())
  vim.cmd("enew")
end

--- source:get_completions() をコールバック待ちで同期的に呼ぶ薄いラッパー。
---@return table response
local function get_completions_sync(src)
  local response
  src:get_completions({}, function(r)
    response = r
  end)
  return response
end

describe("blink_source", function()
  before_each(reset)

  it("phase=='idle'（変換していない）なら空を返す", function()
    local src = source_module.new()
    local response = get_completions_sync(src)
    assert.are.same({}, response.items)
  end)

  it("▽ 状態で前方一致する候補をすべて展開して返す", function()
    state.start_midashi("hira", "k")
    for ch in ("an"):gmatch(".") do
      state.input(ch)
    end
    -- reading == "かん" のはず（かんじ/かんたん/かんこう が前方一致）

    local src = source_module.new()
    local response = get_completions_sync(src)

    local labels = {}
    for _, item in ipairs(response.items) do
      labels[#labels + 1] = item.label
    end
    table.sort(labels)
    -- かんじ(漢字,幹事) + かんたん(簡単) + かんこう(観光) = 4件
    assert.are.same({ "幹事", "観光", "漢字", "簡単" }, labels)
  end)

  it(
    "▼ 状態（select）では空を返す（候補選択中は既存の候補ウィンドウに任せる）",
    function()
      state.start_midashi("hira", "k")
      for ch in ("anji"):gmatch(".") do
        state.input(ch)
      end
      state.space() -- ▼へ遷移
      assert.are.equal("select", state.get_phase())

      local src = source_module.new()
      local response = get_completions_sync(src)
      assert.are.same({}, response.items)
    end
  )

  it("execute() は default_implementation を呼び、個人辞書に記録したうえで確定する", function()
    state.start_midashi("hira", "k")
    for ch in ("an"):gmatch(".") do
      state.input(ch)
    end

    local src = source_module.new()
    local response = get_completions_sync(src)
    local item
    for _, it in ipairs(response.items) do
      if it.label == "漢字" then
        item = it
      end
    end
    assert.is_not_nil(item)

    local default_impl_called = false
    local callback_called = false
    src:execute({}, item, function()
      callback_called = true
    end, function()
      default_impl_called = true
    end)

    assert.is_true(default_impl_called)
    assert.is_true(callback_called)
    assert.are.equal("idle", state.get_phase()) -- 確定してセッションが終わっている

    -- 個人辞書に記録され、次回「かんじ」検索で先頭候補になっているはず
    local candidates = dict.lookup("かんじ", false)
    assert.are.equal("漢字", candidates[1].word)
  end)
end)
