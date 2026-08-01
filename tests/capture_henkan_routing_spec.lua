-- tests/capture_henkan_routing_spec.lua
--
-- lua/skk/capture.lua に組み込んだ henkan（▽/▼）ルーティングロジックの
-- テスト。on_key/handle_henkan_key は vim.on_key() 経由でしか実行されない
-- ローカル関数なので、ここでは同じルーティングルールを、記録するだけの
-- 偽 henkan_state を使って再現し、「どのキーがどの henkan_state 関数を
-- 呼ぶか」「確定後に他のキーがどう再処理されるか」を検証する。
-- 実際の vim.on_key 配線・extmark表示・バッファ挿入自体は plenary/nvim
-- 上での確認が必要。

---@type table[]
local calls

--- lua/skk/capture.lua の handle_henkan_key と同じルーティングルールを、
--- モック henkan_state を使って再現する。
---@param henkan_state table
---@param is_target_key fun(key: string): boolean
---@param key string
---@return boolean reprocess true なら、このキーは直接入力として再処理する
local function handle_henkan_key(henkan_state, is_target_key, key)
  local BS = string.char(8)
  local CR = string.char(13)
  local CTRL_G = string.char(7)

  if key == CR then
    henkan_state.confirm()
    return false
  end
  if key == BS then
    henkan_state.backspace()
    return false
  end
  if key == CTRL_G then
    henkan_state.cancel()
    return false
  end
  if key == " " then
    henkan_state.space()
    return false
  end

  local phase = henkan_state.get_phase()

  if phase == "select" then
    if key == "x" then
      henkan_state.prev_candidate()
      return false
    end
    -- space/x 以外のキーは、選択中の候補を確定したうえで
    -- 直接入力として再処理する。
    henkan_state.confirm()
    return true
  end

  -- ここから phase == "midashi"
  if key == "q" then
    henkan_state.convert_and_confirm_kana()
    return false
  end
  if key:match("%u") then
    -- 送り開始点トリガー
    henkan_state.start_okuri()
    henkan_state.input(key:lower())
    return false
  end
  if is_target_key(key) then
    henkan_state.input(key)
    return false
  end
  henkan_state.cancel()
  return false
end

--- lua/skk/capture.lua の on_key と同じルーティングルールを再現する。
--- henkan アクティブ中に handle_henkan_key が reprocess=true を返したら、
--- 直接入力側の「▽開始トリガー（大文字）」チェックだけ簡易的に再現する
--- （小文字の場合の実際の process_romaji 呼び出しまでは追わない。
-- そこは tests/capture_integration_spec.lua が別途カバーしている）。
---@param henkan_state table
---@param is_target_key fun(key: string): boolean
---@param key string
local function route(henkan_state, is_target_key, key)
  if henkan_state.is_active() then
    local reprocess = handle_henkan_key(henkan_state, is_target_key, key)
    if not reprocess then
      return
    end
  end

  if key:match("%u") then
    henkan_state.start_midashi("hira", key:lower())
    return
  end

  if is_target_key(key) then
    table.insert(calls, { "process_romaji", key })
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
    "start_okuri",
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
      if name == "confirm" then
        -- 確定すると henkan は非アクティブに戻る（実際の state.lua と同じ）
        fake._active = false
        fake._phase = "idle"
      end
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

  it("非アクティブ時、小文字キーでは通常入力として処理される", function()
    local fake = make_fake_state()
    route(fake, is_target_key, "u")
    assert.are.equal("process_romaji", calls[1][1])
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

  it("大文字キーは送り開始点トリガー（start_okuri + input）になる", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "K")
    assert.are.equal("start_okuri", calls[1][1])
    assert.are.equal("input", calls[2][1])
    assert.are.equal("k", calls[2][2])
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

  it("小文字キーは、確定したうえで直接入力として再処理される", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "t")
    assert.are.equal("confirm", calls[1][1])
    assert.are.equal("process_romaji", calls[2][1])
    assert.are.equal("t", calls[2][2])
  end)

  it("大文字キーは、確定したうえで新しい ▽ が開始される", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "T")
    assert.are.equal("confirm", calls[1][1])
    assert.are.equal("start_midashi", calls[2][1])
    assert.are.equal("t", calls[2][3])
  end)
end)
