-- tests/capture_henkan_routing_spec.lua
--
-- lua/skk/capture.lua に組み込んだ henkan（▽/▼）ルーティングロジックの
-- テスト。on_key/handle_henkan_key は vim.on_key() 経由でしか実行されない
-- ローカル関数なので、ここでは同じルーティングルールを、記録するだけの
-- 偽 henkan_state を使って再現し、「どのキーがどの henkan_state 関数を
-- 呼ぶか」を検証する。実際の vim.on_key 配線・extmark表示・バッファ挿入
-- 自体は plenary/nvim 上での確認が必要。

---@type table[]
local calls

--- lua/skk/capture.lua の on_key / handle_henkan_key と同じルーティング
--- ルールを、モック henkan_state を使って再現する。実際の capture.lua は
--- 大文字トリガーを `context.buffer == ""` の場合のみ有効にしているが、
--- この gate は l/q/L のモード切替と全く同じパターンで
--- tests/capture_integration_spec.lua 側で既に検証済みのため、
--- ここでは henkan 固有の新しいルーティングだけに焦点を絞る。
---@param henkan_state table 偽の henkan_state（is_active/get_phase/各アクション記録用）
---@param is_target_key fun(key: string): boolean
---@param key string
local function route(henkan_state, is_target_key, key)
  local BS = string.char(8)
  local CR = string.char(13)
  local CTRL_G = string.char(7)

  if henkan_state.is_active() then
    if key == CR then
      henkan_state.confirm()
      return
    end
    if key == BS then
      henkan_state.backspace()
      return
    end
    if key == CTRL_G then
      henkan_state.cancel()
      return
    end
    if key == " " then
      henkan_state.space()
      return
    end

    local phase = henkan_state.get_phase()
    if phase == "select" then
      if key == "x" then
        henkan_state.prev_candidate()
      end
      return
    end

    if key == "q" then
      henkan_state.convert_and_confirm_kana()
      return
    end
    if is_target_key(key) then
      henkan_state.input(key)
      return
    end
    henkan_state.cancel()
    return
  end

  if key:match("%u") then
    henkan_state.start_midashi("hira", key:lower())
  end
end

--- 偽の henkan_state を作る。呼ばれた関数名を calls に積む。
--- active/phase は外から差し替えられるようにしておく。
local function make_fake_state()
  local fake = {
    _active = false,
    _phase = "idle",
  }
  fake.is_active = function()
    return fake._active
  end
  fake.get_phase = function()
    return fake._phase
  end
  for _, name in ipairs({
    "start_midashi",
    "input",
    "backspace",
    "space",
    "confirm",
    "cancel",
    "convert_and_confirm_kana",
    "next_candidate",
    "prev_candidate",
  }) do
    fake[name] = function(...)
      table.insert(calls, { name, ... })
    end
  end
  return fake
end

local function is_target_key(key)
  if #key ~= 1 then
    return false
  end
  return key:match("%l") ~= nil or key == " "
end

describe("capture henkan routing: ▽ 開始トリガー", function()
  before_each(function()
    calls = {}
  end)

  it("非アクティブ時、大文字キーで start_midashi が呼ばれる", function()
    local fake = make_fake_state()
    route(fake, is_target_key, "U")
    assert.are.equal("start_midashi", calls[1][1])
    assert.are.equal("hira", calls[1][2])
    assert.are.equal("u", calls[1][3])
  end)

  it("非アクティブ時、小文字キーでは何も呼ばれない", function()
    local fake = make_fake_state()
    route(fake, is_target_key, "u")
    assert.are.equal(0, #calls)
  end)
end)

describe("capture henkan routing: 制御キー（フェーズ非依存）", function()
  before_each(function()
    calls = {}
  end)

  it("<CR> は confirm を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, string.char(13))
    assert.are.equal("confirm", calls[1][1])
  end)

  it("<BS> は backspace を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, string.char(8))
    assert.are.equal("backspace", calls[1][1])
  end)

  it("<C-g> は cancel を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, string.char(7))
    assert.are.equal("cancel", calls[1][1])
  end)
end)

describe("capture henkan routing: ▽ (midashi) フェーズ", function()
  before_each(function()
    calls = {}
  end)

  it("スペースは space を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, " ")
    assert.are.equal("space", calls[1][1])
  end)

  it("q は convert_and_confirm_kana を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "q")
    assert.are.equal("convert_and_confirm_kana", calls[1][1])
  end)

  it("x は（▽状態では）通常のローマ字として input に渡る", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "x")
    assert.are.equal("input", calls[1][1])
    assert.are.equal("x", calls[1][2])
  end)

  it("通常の小文字は input を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "a")
    assert.are.equal("input", calls[1][1])
    assert.are.equal("a", calls[1][2])
  end)

  it("未対応のキー（大文字等）は cancel を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "U")
    assert.are.equal("cancel", calls[1][1])
  end)
end)

describe("capture henkan routing: ▼ (select) フェーズ", function()
  before_each(function()
    calls = {}
  end)

  it("スペースは space を呼ぶ（次候補は state.space 内部で処理）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, " ")
    assert.are.equal("space", calls[1][1])
  end)

  it("x は prev_candidate を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "x")
    assert.are.equal("prev_candidate", calls[1][1])
  end)

  it("q は▼状態では何も呼ばない（phase 3 時点では未定義）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "q")
    assert.are.equal(0, #calls)
  end)

  it("通常の小文字は▼状態では何も呼ばない（phase 3 時点では未定義）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "a")
    assert.are.equal(0, #calls)
  end)
end)
