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
local skkserv = require("skk.dict.skkserv")

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

  it("▽ 状態で前方一致する読みの実際の変換候補（漢字）を返す（Phase 2）", function()
    state.start_midashi("hira", "k")
    for ch in ("an"):gmatch(".") do
      state.input(ch)
    end
    -- reading == "かん" のはず（かんじ/かんたん/かんこう が前方一致）。
    -- SKKサーバーは未設定（is_enabled()==false）なので、いずれも
    -- ローカル辞書の候補で完結する。

    local src = source_module.new()
    local response = get_completions_sync(src)

    local labels = {}
    for _, item in ipairs(response.items) do
      labels[#labels + 1] = item.label
    end
    table.sort(labels)
    -- 読みそのものではなく、実際の変換候補（かんじ→漢字/幹事、
    -- かんたん→簡単、かんこう→観光）が返る
    assert.are.same({ "幹事", "漢字", "簡単", "観光" }, labels)
  end)

  it("各候補項目の data に reading/word/annotation が入る（Phase 2）", function()
    state.start_midashi("hira", "k")
    for ch in ("an"):gmatch(".") do
      state.input(ch)
    end

    local src = source_module.new()
    local response = get_completions_sync(src)

    local item
    for _, it in ipairs(response.items) do
      if it.label == "幹事" then
        item = it
      end
    end
    assert.is_not_nil(item)
    assert.are.equal("かんじ", item.data.reading)
    assert.are.equal("幹事", item.data.word)
    -- ローカル辞書のエントリには annotation を付けていないので nil のはず
    assert.is_nil(item.data.annotation)
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

  it(
    "execute() で変換候補（data.word あり）を選ぶと default_implementation を呼び、"
      .. "M.confirm_external() 経由で即座に確定する（Phase 2、v1相当）",
    function()
      state.start_midashi("hira", "k")
      for ch in ("an"):gmatch(".") do
        state.input(ch)
      end

      local src = source_module.new()
      local response = get_completions_sync(src)
      local item
      for _, it in ipairs(response.items) do
        if it.label == "幹事" then
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
      -- 候補そのものを確定したので、▽/▼は終了する（v2の読み補完とは違い、
      -- ここでは<SPC>を経由せず一気に確定する）。
      assert.are.equal("idle", state.get_phase())
    end
  )
end)

-- --- 上限件数を超えた／SKKサーバーにしか無い読みのフォールバック挙動 ---
-- 【注意】tests/fixtures/fake_skkserv.py（Python3が必要）を使った統合
-- テスト。ローカル辞書に無く SKKサーバーにしか無い読み（"てすと"）に
-- 対して、skkserv_candidate_limit=0 で SKKサーバーへの "1" 呼び出しを
-- 強制的に禁止したときに、v2 と同じ「読みのみ」のフォールバック項目に
-- なることを確認する（lua/skk/blink_source.lua の設計方針コメント参照）。
describe(
  "blink_source: skkserv_candidate_limit で切り捨てられた読みのフォールバック（フェイクサーバー統合テスト）",
  function()
    local job_id
    local PORT = 12791

    local function start_fake_server(port)
      local script = debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "fixtures/fake_skkserv.py"
      if vim.fn.executable("python3") ~= 1 then
        return nil
      end
      local id = vim.fn.jobstart({ "python3", script, tostring(port) })
      if id <= 0 then
        return nil
      end
      vim.wait(500)
      return id
    end

    before_each(function()
      state.setup({ candidate_window_threshold = 1 })
      if state.is_active() then
        state.cancel()
      end
      -- "てすと" はローカル辞書には無く、フェイクサーバーの DICT にのみ
      -- 存在する読み（tests/fixtures/fake_skkserv.py 参照）。
      dict.set_dict(parser.parse("だみー /ダミー/"))
      dict.set_user_dict_path(vim.fn.tempname())
      vim.cmd("enew")
      job_id = start_fake_server(PORT)
    end)

    after_each(function()
      if job_id then
        vim.fn.jobstop(job_id)
      end
      skkserv.setup(nil)
    end)

    it(
      "skkserv_candidate_limit=0 なら SKKサーバーにしか無い読みは「読みのみ」項目になる",
      function()
        if not job_id then
          pending("python3 が無いのでスキップ")
          return
        end
        skkserv.setup({ host = "127.0.0.1", port = PORT, encoding = "euc-jp", timeout_ms = 1000 })
        source_module.setup({ max_items = 50, skip_skkserv = false, skkserv_candidate_limit = 0 })

        state.start_midashi("hira", "t")
        for ch in ("esuto"):gmatch(".") do
          state.input(ch)
        end
        -- reading == "てすと" のはず

        local src = source_module.new()
        local response = get_completions_sync(src)

        local item
        for _, it in ipairs(response.items) do
          if it.label == "てすと" then
            item = it
          end
        end
        assert.is_not_nil(item)
        -- 候補（漢字）ではなく読みそのものが label になっている
        assert.is_nil(item.data.word)
        assert.are.equal("てすと", item.data.reading)

        local default_impl_called = false
        src:execute({}, item, function() end, function()
          default_impl_called = true
        end)
        assert.is_true(default_impl_called)
        -- set_reading() 経由なので▽のまま
        assert.are.equal("midashi", state.get_phase())
        assert.are.equal("てすと", state.current_reading())
      end
    )
  end
)
