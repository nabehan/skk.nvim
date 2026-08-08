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

local mode_util = require("skk.mode")

--- lua/skk/capture.lua の handle_henkan_key と同じルーティングルールを、
--- モック henkan_state を使って再現する。
---@param henkan_state table
---@param is_target_key fun(key: string): boolean
---@param key string
---@param sticky_shift { enabled: boolean, key: string }|nil 省略時は { enabled=true, key=";" }
---@return boolean reprocess true なら、このキーは直接入力として再処理する
local function handle_henkan_key(henkan_state, is_target_key, key, sticky_shift)
  sticky_shift = sticky_shift or { enabled = true, key = ";" }
  local BS = string.char(8)
  local BS_ALT = string.char(127)
  -- 実機で確認された、物理 <BS> が termcap 経由で届く内部キーコード
  -- （K_SPECIAL(0x80) + "kb"）。lua/skk/capture.lua では
  -- vim.api.nvim_replace_termcodes("<BS>", true, true, true) で取得する。
  local BS_TERMCODE = string.char(128) .. "kb"
  local CR = string.char(13)
  local CTRL_G = string.char(7)
  local CTRL_Q = string.char(17)
  local CTRL_N = string.char(14)
  local CTRL_P = string.char(16)

  if key == CR then
    henkan_state.confirm()
    return false
  end
  if key == BS or key == BS_ALT or key == BS_TERMCODE then
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
      henkan_state.prev_page()
      return false
    end
    if key == CTRL_N then
      henkan_state.focus_next()
      return false
    end
    if key == CTRL_P then
      henkan_state.focus_prev()
      return false
    end
    if henkan_state.select_by_key(key) then
      henkan_state.confirm()
      return false
    end
    -- space/x/ホームポジション選択 以外のキーは、選択中の候補を
    -- 確定したうえで直接入力として再処理する。
    henkan_state.confirm()
    return true
  end

  if phase == "abbrev" then
    if key == CTRL_Q then
      henkan_state.confirm_abbrev_zenkaku()
      return false
    end
    if is_target_key(key) or key:match("%u") or key:match("%d") then
      -- abbrev は印字可能ASCIIならなんでも見出しに追加する（大文字も）。
      -- このモックの is_target_key は小文字とスペース等しか true にしない
      -- 簡易版なので、大文字・数字も明示的に許可している。
      henkan_state.input_abbrev(key)
      return false
    end
    henkan_state.confirm()
    return false
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
  if sticky_shift.enabled and key == sticky_shift.key then
    -- Sticky-shift の送り開始点トリガー（トリガーキー自体は文字を持たない）
    henkan_state.start_okuri()
    return false
  end
  if is_target_key(key) then
    henkan_state.input(key)
    return false
  end
  henkan_state.confirm()
  return true
end

--- lua/skk/capture.lua の on_key と同じルーティングルールを再現する。
--- henkan アクティブ中に handle_henkan_key が reprocess=true を返したら、
--- 直接入力側の「▽開始トリガー（大文字）」チェックだけ簡易的に再現する
--- （小文字の場合の実際の process_romaji 呼び出しまでは追わない。
-- そこは tests/capture_integration_spec.lua が別途カバーしている）。
---@param henkan_state table
---@param is_target_key fun(key: string): boolean
---@param key string
---@param sticky_shift { enabled: boolean, key: string }|nil 省略時は { enabled=true, key=";" }
local function route(henkan_state, is_target_key, key, sticky_shift)
  sticky_shift = sticky_shift or { enabled = true, key = ";" }

  if henkan_state.is_active() then
    local reprocess = handle_henkan_key(henkan_state, is_target_key, key, sticky_shift)
    if not reprocess then
      return
    end
  end

  -- 【重要】判定順序は「モード切替 (l/q/L) -> ▽開始 -> abbrev」でなければ
  -- ならない。is_midashi_trigger_key 相当の判定（大文字キー全般にマッチ）を
  -- 先にすると、`L`（全角英数への切替キー）が常に▽開始トリガーとして
  -- 食われてしまい、モード切替に到達できなくなる回帰があった。
  -- 実際の lua/skk/capture.lua も同じ順序で判定する（on_key 参照）。
  local target = mode_util.char_transition(key, "hira")
  if target then
    table.insert(calls, { "mode_transition", target })
    return
  end

  if key:match("%u") then
    henkan_state.start_midashi("hira", key:lower())
    return
  end

  if sticky_shift.enabled and key == sticky_shift.key then
    -- Sticky-shift の ▽ 開始トリガー（トリガーキー自体は文字を持たない）
    henkan_state.start_midashi("hira", "")
    return
  end

  if key == "/" then
    -- abbrev モード開始（ASCII文字列そのものを見出しにする変換）。
    henkan_state.start_abbrev("hira")
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
    "start_abbrev",
    "input",
    "input_abbrev",
    "confirm_abbrev_zenkaku",
    "backspace",
    "space",
    "confirm",
    "cancel",
    "convert_and_confirm_kana",
    "next_page",
    "prev_page",
    "focus_next",
    "focus_prev",
    "select_by_key",
  }) do
    fake[name] = function(...)
      table.insert(calls, { name, ... })
      if name == "confirm" then
        -- 確定すると henkan は非アクティブに戻る（実際の state.lua と同じ）
        fake._active = false
        fake._phase = "idle"
      end
      -- select_by_key はデフォルトで nil（＝そのキーの位置に候補が無い）を
      -- 返す。「候補が見つかった」ケースは各テストで
      -- fake.select_by_key を個別に差し替えて検証する。
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

  it("Sticky-shift（;）でも start_midashi が呼ばれ、最初の読みは空文字列になる", function()
    local fake = make_fake_state()
    route(fake, is_target_key, ";")
    assert.are.equal("start_midashi", calls[1][1])
    assert.are.equal("hira", calls[1][2])
    assert.are.equal("", calls[1][3])
  end)

  it("'/' では start_abbrev が呼ばれる（abbrevモード開始）", function()
    local fake = make_fake_state()
    route(fake, is_target_key, "/")
    assert.are.equal("start_abbrev", calls[1][1])
    assert.are.equal("hira", calls[1][2])
  end)

  it(
    "回帰テスト: 'L' は▽開始トリガーより先にモード切替(全角英数)として判定される",
    function()
      -- 過去、大文字キー全般にマッチする▽開始判定がモード切替判定より
      -- 先に走っていたため、'L' が常に▽開始として食われてしまい、
      -- ひらがな/カタカナモードで 'L' を打っても全角英数に遷移できない
      -- 不具合があった。
      local fake = make_fake_state()
      route(fake, is_target_key, "L")
      assert.are.equal("mode_transition", calls[1][1])
      assert.are.equal("zenei", calls[1][2])
      assert.are.equal(nil, calls[2]) -- start_midashi は呼ばれない
    end
  )
end)

describe("capture henkan routing: Sticky-shift の設定（有効/無効・キー変更）", function()
  before_each(function()
    calls = {}
  end)

  it("sticky_shift_enabled=false なら ';' はただの文字として通常入力になる", function()
    local fake = make_fake_state()
    route(fake, is_target_key, ";", { enabled = false, key = ";" })
    assert.are.equal(nil, calls[1]) -- is_target_key(";") は false（記号のため）なので何も呼ばれない
  end)

  it("sticky_shift_key を変更すると、そのキーで start_midashi が呼ばれる", function()
    local fake = make_fake_state()
    route(fake, is_target_key, "'", { enabled = true, key = "'" })
    assert.are.equal("start_midashi", calls[1][1])
    assert.are.equal("", calls[1][3])
  end)

  it("sticky_shift_key を変更すると、元の ';' はもう Sticky-shift として扱われない", function()
    local fake = make_fake_state()
    route(fake, is_target_key, ";", { enabled = true, key = "'" })
    assert.are.equal(nil, calls[1])
  end)

  it("▽の中でも、変更後のキーが送り開始点トリガーとして働く", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, "'", { enabled = true, key = "'" })
    assert.are.equal("start_okuri", calls[1][1])
    assert.are.equal(nil, calls[2])
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

  it("<BS> (生バイト 0x08) は backspace を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, string.char(8))
    assert.are.equal("backspace", calls[1][1])
  end)

  it("物理 <BS> が termcap 経由の内部キーコードで届いても backspace を呼ぶ", function()
    -- 実機で報告されたケース: 物理 Backspace キーが 0x08 でも 0x7F でもなく、
    -- K_SPECIAL(0x80) + "kb" という3バイト列として vim.on_key() に届いた。
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, string.char(128) .. "kb")
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

  it("Sticky-shift（;）は送り開始点トリガーになるが、文字は消費しない", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "midashi"
    route(fake, is_target_key, ";")
    assert.are.equal("start_okuri", calls[1][1])
    assert.are.equal(nil, calls[2])
  end)
end)

describe('capture henkan routing: abbrev フェーズ（"/" 開始、ASCII見出し）', function()
  before_each(function()
    calls = {}
  end)

  it("印字可能ASCII文字（大文字含む）はそのまま input_abbrev に渡る", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "abbrev"
    route(fake, is_target_key, "B")
    assert.are.equal("input_abbrev", calls[1][1])
    assert.are.equal("B", calls[1][2]) -- 小文字化されない（見出しはASCIIそのまま）
  end)

  it("スペースは（フェーズ非依存の共通処理で）space を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "abbrev"
    route(fake, is_target_key, " ")
    assert.are.equal("space", calls[1][1])
  end)

  it("<C-q> は confirm_abbrev_zenkaku を呼ぶ（全角変換して確定）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "abbrev"
    route(fake, is_target_key, string.char(17))
    assert.are.equal("confirm_abbrev_zenkaku", calls[1][1])
    assert.are.equal(nil, calls[2])
  end)

  it("矢印キー等、印字可能ASCIIでないキーは確定のみ行う（再処理しない）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "abbrev"
    route(fake, is_target_key, string.char(27)) -- ESC相当（印字可能ASCII外）を模したダミー
    assert.are.equal("confirm", calls[1][1])
    assert.are.equal(nil, calls[2])
  end)
end)

describe("capture henkan routing: ▼ (select) フェーズ", function()
  before_each(function()
    calls = {}
  end)

  it("スペースは space を呼ぶ（次ページは state.space 内部で処理）", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, " ")
    assert.are.equal("space", calls[1][1])
  end)

  it("x は prev_page を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "x")
    assert.are.equal("prev_page", calls[1][1])
  end)

  it("<C-n> は focus_next を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, string.char(14))
    assert.are.equal("focus_next", calls[1][1])
  end)

  it("<C-p> は focus_prev を呼ぶ", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, string.char(16))
    assert.are.equal("focus_prev", calls[1][1])
  end)

  it(
    "ホームポジションキー（a s d f j k l）で、その位置に候補があれば選択して即確定する",
    function()
      local fake = make_fake_state()
      fake._active = true
      fake._phase = "select"
      fake.select_by_key = function(key)
        table.insert(calls, { "select_by_key", key })
        return "期" -- 2番目（s）の候補が見つかったことにする
      end
      route(fake, is_target_key, "s")
      assert.are.equal("select_by_key", calls[1][1])
      assert.are.equal("s", calls[1][2])
      assert.are.equal("confirm", calls[2][1])
      -- 選択・確定のみで、直接入力としての再処理は起きない
      assert.are.equal(nil, calls[3])
    end
  )

  it(
    "ホームポジションキーでも、その位置に候補が無ければ確定したうえで直接入力として再処理される",
    function()
      local fake = make_fake_state()
      fake._active = true
      fake._phase = "select"
      route(fake, is_target_key, "s") -- デフォルトの select_by_key は nil を返す
      assert.are.equal("select_by_key", calls[1][1])
      assert.are.equal("confirm", calls[2][1])
      assert.are.equal("process_romaji", calls[3][1])
      assert.are.equal("s", calls[3][2])
    end
  )

  it(
    "小文字キー（ホームポジション以外）は、確定したうえで直接入力として再処理される",
    function()
      local fake = make_fake_state()
      fake._active = true
      fake._phase = "select"
      route(fake, is_target_key, "t")
      assert.are.equal("select_by_key", calls[1][1])
      assert.are.equal("confirm", calls[2][1])
      assert.are.equal("process_romaji", calls[3][1])
      assert.are.equal("t", calls[3][2])
    end
  )

  it("大文字キーは、確定したうえで新しい ▽ が開始される", function()
    local fake = make_fake_state()
    fake._active = true
    fake._phase = "select"
    route(fake, is_target_key, "T")
    assert.are.equal("select_by_key", calls[1][1])
    assert.are.equal("confirm", calls[2][1])
    assert.are.equal("start_midashi", calls[3][1])
    assert.are.equal("t", calls[3][3])
  end)

  it(
    "Sticky-shift（;）はホームポジションキーではないので、確定したうえで新しい ▽ が開始される",
    function()
      local fake = make_fake_state()
      fake._active = true
      fake._phase = "select"
      route(fake, is_target_key, ";")
      assert.are.equal("select_by_key", calls[1][1])
      assert.are.equal("confirm", calls[2][1])
      assert.are.equal("start_midashi", calls[3][1])
      assert.are.equal("", calls[3][3])
    end
  )
end)
