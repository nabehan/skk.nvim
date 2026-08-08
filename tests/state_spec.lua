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
  anchor_win = function()
    return 1000 -- 固定のダミー winid
  end,
}

-- --- 偽の candidate_window（呼び出し履歴を記録するだけ） ---
-- 実物（lua/skk/henkan/candidate_window.lua）は nvim_open_win 等の
-- 本物の vim.api に依存するため、ここでは state.lua が「候補一覧の
-- 表示/非表示をいつ・どんな引数で呼んだか」だけを検証できるようにする。
local candidate_window_calls = {}
package.loaded["skk.henkan.candidate_window"] = {
  HOME_ROW_KEYS = { "a", "s", "d", "f", "j", "k", "l" },
  show = function(anchor_win, row, col, candidates, page, page_count, selected_offset)
    table.insert(
      candidate_window_calls,
      { "show", anchor_win, row, col, candidates, page, page_count, selected_offset }
    )
  end,
  hide = function()
    table.insert(candidate_window_calls, { "hide" })
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
  candidate_window_calls = {}
  buf_set_text_calls = {}
  -- 既存のテスト群は「▼開始と同時にウィンドウを表示する」旧来の挙動
  -- （= threshold 1）を前提に書かれているので固定しておく。
  -- threshold 自体の挙動は別の describe ブロックで検証する。
  state.setup({ candidate_window_threshold = 1 })
  if state.is_active() then
    state.cancel()
    preedit_calls = {} -- cancel 自体の呼び出し履歴は捨てる
    candidate_window_calls = {}
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

  it(
    "kata モードで開始すると ▽ 表示はカタカナになる（内部の読みはひらがなのまま）",
    function()
      state.start_midashi("kata", "k")
      state.input("a")
      local call = last_preedit_call()
      assert.are.equal("show_midashi", call[1])
      assert.are.equal("カ", call[2])
    end
  )
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

  it(
    'Sticky-shift（;）は最初の読みを持たずに ▽ を始められる（start_midashi(mode, "")）',
    function()
      -- capture.lua は `;` トリガーのとき first_char に "" を渡す
      -- （大文字キーと違い、`;` 自体は文字を持たないため）。
      state.start_midashi("hira", "")
      assert.are.equal("midashi", state.get_phase())
      state.input("u")
      state.input("g")
      state.input("o")
      dict.set_dict(parser.parse("うご /動/"))
      state.space()
      assert.are.equal("select", state.get_phase())
    end
  )
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

  it(
    "候補一覧ウィンドウには、アノテーション付きの候補オブジェクトがそのまま渡る",
    function()
      dict.set_dict(parser.parse("かんじ /漢字;人名用/幹事/"))
      state.start_midashi("hira", "k")
      for ch in ("anji"):gmatch(".") do
        state.input(ch)
      end
      state.space()
      local last_show = candidate_window_calls[#candidate_window_calls]
      assert.are.equal("show", last_show[1])
      local page = last_show[5]
      assert.are.equal("漢字", page[1].word)
      assert.are.equal("人名用", page[1].annotation)
      assert.are.equal("幹事", page[2].word)
      assert.is_nil(page[2].annotation)
    end
  )

  it(
    "▼状態で s キー（ホームポジション2番目）を押すと2番目の候補が選ばれ確定する",
    function()
      state.start_midashi("hira", "k")
      for ch in ("anji"):gmatch(".") do
        state.input(ch)
      end
      state.space() -- 検索 -> ▼、候補1 "漢字"、候補一覧は a:漢字 s:幹事 d:監事
      local selected = state.select_by_key("s") -- 2番目の候補「幹事」
      assert.are.equal("幹事", selected.word)
      state.confirm()
      assert.are.equal("幹事", last_inserted_text())
    end
  )

  it("select_by_key は、その位置に候補が無ければ nil を返し、選択状態を変えない", function()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space() -- 候補は3件（漢字/幹事/監事）しかない
    local selected = state.select_by_key("j") -- 5番目、候補なし
    assert.is_nil(selected)
    state.confirm()
    assert.are.equal("漢字", last_inserted_text()) -- 先頭候補のまま
  end)

  it(
    "候補が7件を超えるとページが分かれ、<SPC>で次ページ・xで前ページに切り替わる",
    function()
      dict.set_dict(parser.parse("かんじ /1/2/3/4/5/6/7/8/9/"))
      state.start_midashi("hira", "k")
      for ch in ("anji"):gmatch(".") do
        state.input(ch)
      end
      state.space() -- 1ページ目: 1〜7
      state.space() -- <SPC> は select 状態では次ページ。2ページ目: 8,9
      state.confirm()
      assert.are.equal("8", last_inserted_text())
    end
  )

  it("候補一覧ウィンドウには現在ページ番号と全ページ数が渡る", function()
    dict.set_dict(parser.parse("かんじ /1/2/3/4/5/6/7/8/9/")) -- 9件 -> 2ページ
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space() -- 1ページ目
    local last_show = candidate_window_calls[#candidate_window_calls]
    assert.are.equal("show", last_show[1])
    assert.are.equal(1, last_show[6]) -- page (1-indexed)
    assert.are.equal(2, last_show[7]) -- page_count

    state.space() -- 2ページ目へ
    last_show = candidate_window_calls[#candidate_window_calls]
    assert.are.equal(2, last_show[6])
    assert.are.equal(2, last_show[7])
  end)

  it("前ページ（x）は先頭ページの前で末尾ページに循環する", function()
    dict.set_dict(parser.parse("かんじ /1/2/3/4/5/6/7/8/9/"))
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
    state.space() -- 1ページ目
    state.prev_page() -- 先頭ページの前 -> 末尾ページ（8,9）に循環
    state.confirm()
    assert.are.equal("8", last_inserted_text())
  end)
end)

describe("state: 確定・キャンセル", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/"))
  end)

  it(
    "▽状態で confirm すると読みをそのまま確定する（辞書検索していない場合）",
    function()
      state.start_midashi("hira", "u")
      state.input("g")
      state.input("o")
      state.confirm()
      assert.are.equal("うご", last_inserted_text())
      assert.are.equal("idle", state.get_phase())
    end
  )

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

  it(
    "カタカナモードの ▽ で q を打っても、q は常にカタカナ確定なので変わらずカタカナになる",
    function()
      -- 設計ルール③: <CR> は常にひらがな確定、q は常にカタカナ確定。
      -- source_mode には依存しない固定ルール。
      state.start_midashi("kata", "k")
      state.input("a")
      state.convert_and_confirm_kana()
      assert.are.equal("カ", last_inserted_text())
    end
  )
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

  it(
    "送り開始点のあと、子音+母音が確定すると自動的に▼へ遷移する（スペース不要）",
    function()
      state.start_midashi("hira", "u")
      state.input("g")
      state.input("o") -- reading = "うご"
      state.start_okuri()
      state.input("k") -- 子音のみ、まだ▼にならない
      assert.are.equal("midashi", state.get_phase())
      state.input("a") -- "ka" -> "か" 確定 -> 自動的に▼へ
      assert.are.equal("select", state.get_phase())
    end
  )

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

describe('state: abbrev モード（"/" 開始、ASCII見出し）', function()
  before_each(function()
    reset()
  end)

  it("start_abbrev で abbrev フェーズが始まる", function()
    state.start_abbrev("hira")
    assert.are.equal("abbrev", state.get_phase())
    assert.is_true(state.is_active())
  end)

  it("input_abbrev はローマ字変換せず ASCII をそのまま積む（大文字も可）", function()
    dict.set_dict(parser.parse("Bug /バグ/"))
    state.start_abbrev("hira")
    for ch in ("Bug"):gmatch(".") do
      state.input_abbrev(ch)
    end
    state.space() -- "Bug" というASCII文字列そのものを検索キーにする
    assert.are.equal("select", state.get_phase())
    state.confirm()
    assert.are.equal("バグ", last_inserted_text())
  end)

  it("<CR> 相当（confirm）は、検索前なら見出しのASCII文字列をそのまま確定する", function()
    state.start_abbrev("hira")
    for ch in ("abbrev"):gmatch(".") do
      state.input_abbrev(ch)
    end
    state.confirm()
    assert.are.equal("abbrev", last_inserted_text())
  end)

  it("<BS> 相当は1文字ずつ消え、空になったらセッションを中断する", function()
    state.start_abbrev("hira")
    state.input_abbrev("x")
    state.input_abbrev("y")
    state.backspace()
    assert.is_true(state.is_active())
    state.backspace()
    assert.is_false(state.is_active()) -- 空になったのでキャンセル扱い
  end)

  it("<C-q> 相当（confirm_abbrev_zenkaku）は、見出しを全角変換して確定する", function()
    state.start_abbrev("hira")
    for ch in ("manager"):gmatch(".") do
      state.input_abbrev(ch)
    end
    state.confirm_abbrev_zenkaku()
    assert.are.equal("ｍａｎａｇｅｒ", last_inserted_text())
    assert.is_false(state.is_active())
  end)

  it("候補が見つからなければ、ASCII文字列そのままプレーンテキストで確定する", function()
    state.start_abbrev("hira")
    for ch in ("nosuchword"):gmatch(".") do
      state.input_abbrev(ch)
    end
    state.space()
    assert.are.equal("nosuchword", last_inserted_text())
  end)
end)

describe("state: 候補一覧ウィンドウの表示タイミング（candidate_window_threshold）", function()
  before_each(function()
    reset()
    dict.set_dict(parser.parse("かんじ /漢字/幹事/監事/幹事長/"))
  end)

  local function start_kanji_henkan()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
  end

  it("threshold=1（デフォルトの前の挙動）: 最初の<SPC>で即ウィンドウ表示", function()
    state.setup({ candidate_window_threshold = 1 })
    start_kanji_henkan()
    state.space() -- 1回目
    assert.are.equal("show", candidate_window_calls[#candidate_window_calls][1])
  end)

  it(
    "threshold=3: 1・2回目はインラインのみ、3回目でウィンドウ表示（ユーザー提示の例と同じ）",
    function()
      state.setup({ candidate_window_threshold = 3 })
      start_kanji_henkan()

      state.space() -- 1回目: インラインのみ、候補1「漢字」
      assert.are.equal(0, #candidate_window_calls)
      local show1 = preedit_calls[#preedit_calls]
      assert.are.equal("show_henkan", show1[1])
      assert.are.equal("漢字", show1[2])

      state.space() -- 2回目: インラインのみ、候補2「幹事」
      assert.are.equal(0, #candidate_window_calls)
      local show2 = preedit_calls[#preedit_calls]
      assert.are.equal("幹事", show2[2])

      state.space() -- 3回目: 候補3「監事」に進み、ここでウィンドウ表示
      assert.are.equal(1, #candidate_window_calls)
      local win_call = candidate_window_calls[#candidate_window_calls]
      assert.are.equal("show", win_call[1])
      local show3 = preedit_calls[#preedit_calls]
      assert.are.equal("監事", show3[2])
      -- 回帰テスト: インラインで表示中の候補（3番目「監事」）と、候補一覧
      -- ウィンドウ内でハイライトされる位置（3番目 = d）が一致すること。
      -- 以前はウィンドウが必ずページ先頭（a）を選択中として扱っていたため、
      -- 単独送りの途中でウィンドウが現れると、インライン表示（監事）と
      -- ウィンドウの見た目上の「選択中」（先頭の漢字）がズレていた。
      assert.are.equal(3, win_call[8]) -- selected_offset

      -- 確定すると、その時点でインライン表示していた候補（監事）が挿入される
      state.confirm()
      assert.are.equal("監事", last_inserted_text())
    end
  )

  it("threshold到達後の<SPC>は、通常どおりページ送り（7候補ずつ）になる", function()
    dict.set_dict(parser.parse("かんじ /1/2/3/4/5/6/7/8/9/"))
    state.setup({ candidate_window_threshold = 2 })
    start_kanji_henkan()

    state.space() -- 1回目: インラインのみ、候補1「1」
    state.space() -- 2回目: 候補2「2」に進み、ウィンドウ表示（まだ1ページ目の中）
    local show2 = candidate_window_calls[#candidate_window_calls]
    assert.are.equal(1, show2[6]) -- page（1-indexed） = 1ページ目のまま

    state.space() -- 3回目: 閾値到達後なので、ここからページ送り(+7)
    local show3 = candidate_window_calls[#candidate_window_calls]
    assert.are.equal(2, show3[6]) -- 2ページ目へ
    state.confirm()
    assert.are.equal("8", last_inserted_text())
  end)

  it("ウィンドウ表示前の x は、1件ずつ戻すだけでウィンドウは表示しない", function()
    state.setup({ candidate_window_threshold = 3 })
    start_kanji_henkan()

    state.space() -- 候補1「漢字」
    state.space() -- 候補2「幹事」
    state.prev_page() -- x: 候補1「漢字」に戻る（ウィンドウはまだ出さない）
    assert.are.equal(0, #candidate_window_calls)
    local show = preedit_calls[#preedit_calls]
    assert.are.equal("漢字", show[2])
  end)
end)

describe("state: focus_next/focus_prev（<C-n>/<C-p> 相当）", function()
  before_each(function()
    reset()
    state.setup({ candidate_window_threshold = 1 }) -- ウィンドウは最初から表示されている状態にする
    dict.set_dict(parser.parse("かんじ /1/2/3/4/5/6/7/8/9/")) -- 9件 -> 2ページ
  end)

  local function start_kanji_henkan()
    state.start_midashi("hira", "k")
    for ch in ("anji"):gmatch(".") do
      state.input(ch)
    end
  end

  it("focus_next は次の1候補にフォーカスを移し、常にウィンドウを表示する", function()
    start_kanji_henkan()
    state.space() -- ▼開始、候補1「1」、ウィンドウ表示
    state.focus_next() -- 候補2「2」
    local show = preedit_calls[#preedit_calls]
    assert.are.equal("2", show[2])
    local win_call = candidate_window_calls[#candidate_window_calls]
    assert.are.equal("show", win_call[1])
    assert.are.equal(2, win_call[8]) -- selected_offset（1ページ目の2番目）
  end)

  it(
    "ページ末尾（l: 7番目）で focus_next すると、次ページの先頭（a）にフォーカスする",
    function()
      start_kanji_henkan()
      state.space() -- 候補1「1」
      for _ = 1, 6 do
        state.focus_next() -- 候補2..7「2」..「7」
      end
      -- ここで候補7「7」（1ページ目の末尾 = l）にいるはず
      assert.are.equal("7", preedit_calls[#preedit_calls][2])

      state.focus_next() -- 折り返して2ページ目の先頭（候補8「8」）へ
      local show = preedit_calls[#preedit_calls]
      assert.are.equal("8", show[2])
      local win_call = candidate_window_calls[#candidate_window_calls]
      assert.are.equal(2, win_call[6]) -- 2ページ目
      assert.are.equal(1, win_call[8]) -- ページ内の1番目（a）
    end
  )

  it("先頭候補（a）で focus_prev すると、前ページの末尾候補にフォーカスする", function()
    start_kanji_henkan()
    state.space() -- 候補1「1」（1ページ目の先頭 = a）
    state.focus_prev() -- 折り返して、全候補中の最後（候補9「9」、2ページ目の2番目）へ
    local show = preedit_calls[#preedit_calls]
    assert.are.equal("9", show[2])
    local win_call = candidate_window_calls[#candidate_window_calls]
    assert.are.equal(2, win_call[6]) -- 2ページ目
    assert.are.equal(2, win_call[7]) -- 全2ページ
    assert.are.equal(2, win_call[8]) -- 2ページ目の2番目（s の位置。2ページ目は候補2件しか無いため）
  end)

  it("<CR>相当（confirm）で、フォーカス中の候補が確定する", function()
    start_kanji_henkan()
    state.space()
    state.focus_next()
    state.focus_next()
    state.confirm()
    assert.are.equal("3", last_inserted_text())
  end)
end)
