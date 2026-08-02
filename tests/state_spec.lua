-- tests/state_spec.lua
--
-- lua/skk/henkan/state.lua のテスト。
--
-- state.lua は lua/skk/henkan/preedit.lua（vim.* 依存）と、vim.schedule /
-- vim.notify / vim.api.nvim_buf_set_text 等に直接依存している。
-- ここではテスト用の偽実装を package.loaded / _G.vim に差し込んでから
-- state.lua を require することで、実 Neovim 無しでも状態遷移ロジックを
-- 検証できるようにする。
--
-- 【前提】このファイルは `PlenaryBustedDirectory` 経由（tests/ 配下の
-- 各ファイルごとに独立した headless Neovim プロセスで実行される）で
-- 実行することを想定している。ここでの vim.api の差し替えが他の
-- スペックファイルに漏れることはない。

-- --- 偽の preedit（呼び出し履歴を記録するだけ） ---
local preedit_calls = {}
package.loaded["skk.henkan.preedit"] = {
  anchor = function()
    table.insert(preedit_calls, { "anchor" })
  end,
  is_anchored = function()
    return true
  end,
  show_midashi = function(reading, okuri)
    table.insert(preedit_calls, { "show_midashi", reading, okuri })
  end,
  show_henkan = function(cand, okuri)
    table.insert(preedit_calls, { "show_henkan", cand, okuri })
  end,
  show_abbrev = function(reading)
    table.insert(preedit_calls, { "show_abbrev", reading })
  end,
  hide = function()
    table.insert(preedit_calls, { "hide" })
  end,
  anchor_position = function()
    return 1, 0, 0 -- bufnr=1, row=0, col=0 の固定値
  end,
}

-- --- vim.* の最小限のダミー実装 ---
local buf_set_text_calls = {}
_G.vim = _G.vim or {}
vim.schedule = function(fn)
  fn()
end -- テストでは同期的に即実行する
vim.notify = function(...) end
vim.log = { levels = { INFO = 1 } }
vim.api = vim.api or {}
vim.api.nvim_buf_set_text = function(bufnr, r1, c1, r2, c2, lines)
  table.insert(buf_set_text_calls, { bufnr = bufnr, row = r1, col = c1, text = lines[1] })
end
vim.api.nvim_win_set_cursor = function(_, _) end

local state = require("skk.henkan.state")
local dict = require("skk.dict")
local parser = require("skk.dict.jisyo_parser")

local function reset()
  preedit_calls = {}
  buf_set_text_calls = {}
  if state.is_active() then
    state.cancel()
    preedit_calls = {} -- cancel 自体の呼び出し履歴は捨てる
  end
end

local function last_inserted_text()
  local last = buf_set_text_calls[#buf_set_text_calls]
  return last and last.text or nil
end

local function last_preedit_call()
  return preedit_calls[#preedit_calls]
end

describe("state: ▽ の表示は source_mode に連動する（②）", function()
  before_each(reset)

  it("hira モードで開始すると ▽ 表示はひらがなのまま", function()
    state.start_midashi("hira", "k")
    state.input("a")
    local call = last_preedit_call()
    assert.are.equal("show_midashi", call[1])
    assert.are.equal("か", call[2])
  end)

  it("kata モードで開始すると ▽ 表示はカタカナになる（内部の読みはひらがなのまま）", function()
    state.start_midashi("kata", "k")
    state.input("a")
    local call = last_preedit_call()
    assert.are.equal("show_midashi", call[1])
    assert.are.equal("カ", call[2])
  end)
end)

describe("state: ▽ 表示に未確定のローマ字断片が含まれる（回帰テスト）", function()
  -- 以前、▽ の表示が session.reading（確定済み部分）だけを見ており、
  -- 未確定のローマ字断片（例: "kan" と打った直後の "n"）が表示から
  -- 抜け落ちていた。"K"->"▽"、"Kan"->"▽か"（"n" が消える）のように、
  -- 打鍵と表示が一致しない不具合として実際に報告された。
  before_each(reset)

  it("K の直後は ▽k （まだ何も確定していない）", function()
    state.start_midashi("hira", "k")
    local call = last_preedit_call()
    assert.are.equal("show_midashi", call[1])
    assert.are.equal("k", call[2])
  end)

  it("Kan の直後は ▽かn （か確定 + n が未確定のまま表示される）", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.input("n")
    local call = last_preedit_call()
    assert.are.equal("かn", call[2])
  end)

  it("Kanj の直後は ▽かんj （ん確定 + j が未確定のまま表示される）", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.input("n")
    state.input("j")
    local call = last_preedit_call()
    assert.are.equal("かんj", call[2])
  end)
end)

describe("state: ▽ 開始・ローマ字入力", function()
  before_each(reset)

  it("start_midashi で ▽ が始まる", function()
    state.start_midashi("hira", "u")
    assert.are.equal("midashi", state.get_phase())
    assert.is_true(state.is_active())
  end)

  it("input() で読みが蓄積される", function()
    state.start_midashi("hira", "u")
    state.input("g")
    state.input("o")
    -- session の中身は state.lua の外から直接見えないので、
    -- ▼へ遷移させて dict_key 経由の検索結果で間接的に確認する。
    dict.set_dict(parser.parse("うご /動/"))
    state.space()
    assert.are.equal("select", state.get_phase())
  end)
end)

describe("state: 辞書検索と▼遷移", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse(table.concat({
      "かんじ /漢字/幹事/監事/",
    }, "\n")))
  end)

  it("スペースで検索し ▼ へ遷移する", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.input("n")
    state.input("j")
    state.input("i")
    state.space()
    assert.are.equal("select", state.get_phase())
  end)

  it("▼状態でスペースは次候補へ進む", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space() -- 検索 -> ▼、候補1 "漢字"
    state.next_candidate() -- 候補2 "幹事"
    state.confirm()
    assert.are.equal("幹事", last_inserted_text())
  end)

  it("x で前候補へ戻る", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space()
    state.next_candidate() -- "幹事"
    state.next_candidate() -- "監事"
    state.prev_candidate() -- "幹事" に戻る
    state.confirm()
    assert.are.equal("幹事", last_inserted_text())
  end)

  it("候補送りは循環する", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space() -- "漢字"
    state.next_candidate() -- "幹事"
    state.next_candidate() -- "監事"
    state.next_candidate() -- 先頭に戻って "漢字"
    state.confirm()
    assert.are.equal("漢字", last_inserted_text())
  end)
end)

describe("state: 確定・キャンセル", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/"))
  end)

  it("▽状態で confirm すると読みをそのまま確定する（辞書検索していない場合）", function()
    state.start_midashi("hira", "u")
    state.input("g")
    state.input("o")
    state.confirm()
    assert.are.equal("うご", last_inserted_text())
    assert.are.equal("idle", state.get_phase())
  end)

  it("▼状態で confirm すると選択中の候補を確定する", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space()
    state.confirm()
    assert.are.equal("漢字", last_inserted_text())
    assert.are.equal("idle", state.get_phase())
  end)

  it("cancel すると何も確定せずセッションが終わる", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.cancel()
    assert.are.equal("idle", state.get_phase())
    assert.are.equal(0, #buf_set_text_calls)
  end)

  it("確定後は is_active が false になる", function()
    state.start_midashi("hira", "u")
    state.confirm()
    assert.is_false(state.is_active())
  end)
end)

describe("state: <BS> 相当（backspace）", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/"))
  end)

  it("読みを1文字消す", function()
    state.start_midashi("hira", "k")
    state.input("a") -- reading = "か"
    state.backspace() -- reading = ""(空になるのでセッション終了) のはず

    -- "ka" の2文字目の "a" を消した時点でまだ "か" という1文字だが、
    -- backspace_reading は reading が空でなければ継続するので、
    -- ここでは reading="" になりセッションごと終了する。
    assert.are.equal("idle", state.get_phase())
  end)

  it("読みが複数文字あれば、1文字消してセッションは継続する", function()
    state.start_midashi("hira", "k")
    state.input("a") -- "か"
    state.input("n")
    state.input("j")
    state.input("i") -- reading = "かんじ"
    state.backspace() -- reading = "かん"
    assert.are.equal("midashi", state.get_phase())
  end)
end)

describe("state: 候補ゼロ件のフォールバック", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/")) -- "みつからない" は登録しない
  end)

  it("読みをそのままプレーンテキストで確定する", function()
    state.start_midashi("hira", "m")
    for ch in ("itukaranai"):gmatch(".") do
      state.input(ch)
    end
    state.space()
    assert.are.equal("idle", state.get_phase()) -- フォールバックで即確定するので idle に戻る
    assert.are.equal("みつからない", last_inserted_text())
  end)
end)

describe("state: q によるかな変換確定（▽状態のみ、常にカタカナ確定）", function()
  before_each(reset)

  it("ひらがなモードの ▽ で q を打つとカタカナで確定する", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.input("n")
    state.input("j")
    state.input("i")
    state.convert_and_confirm_kana()
    assert.are.equal("カンジ", last_inserted_text())
    assert.are.equal("idle", state.get_phase())
  end)

  it("カタカナモードの ▽ で q を打っても、q は常にカタカナ確定なので変わらずカタカナになる", function()
    -- 設計ルール③: <CR> は常にひらがな確定、q は常にカタカナ確定。
    -- source_mode には依存しない固定ルール。
    state.start_midashi("kata", "k")
    state.input("a")
    state.convert_and_confirm_kana()
    assert.are.equal("カ", last_inserted_text())
  end)
end)

describe("state: <CR> は常にひらがな確定（▽状態、ルール③）", function()
  before_each(reset)

  it("カタカナモードの ▽ で <CR>（confirm）してもひらがなで確定する", function()
    state.start_midashi("kata", "k")
    state.input("a")
    state.confirm()
    assert.are.equal("か", last_inserted_text())
  end)
end)

describe("state._render_for_mode (② ▽表示は source_mode に連動)", function()
  it("hira モードはそのまま返す", function()
    assert.are.equal("かんじ", state._render_for_mode("かんじ", "hira"))
  end)

  it("kata モードはカタカナに変換する", function()
    assert.are.equal("カンジ", state._render_for_mode("かんじ", "kata"))
  end)
end)

describe("state: 送りあり変換（okuri-ari）", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse(table.concat({
      ";; okuri-ari entries.",
      "うごk /動/",
      ";; okuri-nasi entries.",
      "かんじ /漢字/",
    }, "\n")))
  end)

  it("送り開始点のあと、子音+母音が確定すると自動的に▼へ遷移する（スペース不要）", function()
    state.start_midashi("hira", "u")
    state.input("g")
    state.input("o") -- reading = "うご"
    state.start_okuri()
    state.input("k") -- 子音のみ、まだ▼にならない
    assert.are.equal("midashi", state.get_phase())
    state.input("a") -- "ka" -> "か" 確定 -> 自動的に▼へ
    assert.are.equal("select", state.get_phase())
  end)

  it("確定すると候補+送り仮名が挿入される", function()
    state.start_midashi("hira", "u")
    state.input("g")
    state.input("o")
    state.start_okuri()
    state.input("k")
    state.input("a")
    state.confirm()
    assert.are.equal("動か", last_inserted_text())
  end)

  it("▽表示は '▽よみ*子音' の形式になる（送り開始点確定後）", function()
    state.start_midashi("hira", "u")
    state.input("g")
    state.input("o")
    state.start_okuri()
    state.input("k")
    local call = last_preedit_call()
    assert.are.equal("show_midashi", call[1])
    assert.are.equal("うご", call[2])
    assert.are.equal("k", call[3])
  end)

  it("送りありで候補ゼロ件のときは、読み+送り仮名をそのまま確定する", function()
    state.start_midashi("hira", "a") -- 辞書に無い読み
    state.input("k") -- pending
    state.start_okuri()
    state.input("k")
    state.input("u") -- "aku" は辞書に無い -> フォールバック
    assert.are.equal("idle", state.get_phase())
    assert.are.equal("あく", last_inserted_text())
  end)
end)

describe("state: ▼状態で通常キーが来たら自動確定して継続入力できる", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/"))
  end)

  it("▼状態は is_active/get_phase から観測できる（自動確定の前提）", function()
    state.start_midashi("hira", "k")
    state.input("a")
    state.input("n")
    state.input("j")
    state.input("i")
    state.space()
    assert.are.equal("select", state.get_phase())
    assert.is_true(state.is_active())
    -- 実際の「他のキーで自動確定して継続入力する」ルーティングは
    -- capture.lua 側（handle_henkan_key）の責務なので、
    -- tests/capture_henkan_routing_spec.lua 側で検証する。
    state.confirm()
    assert.are.equal("漢字", last_inserted_text())
    assert.is_false(state.is_active())
  end)
end)
