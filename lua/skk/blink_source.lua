-- lua/skk/blink_source.lua
--
-- blink.cmp 用のネイティブソース。`▽`/abbrev（見出し語入力中）状態の
-- ときだけ、dict.lookup_prefix() による前方一致検索の「読み一覧」を
-- ライブ補完として出す。
--
-- 【設計方針・v2（skkeleton 方式に合わせた）】
-- 実機での性能検証の結果、以前の実装（前方一致で見つかった読みごとに
-- 実際の変換候補まで dict.lookup()（"1" コマンド）で取得し、漢字候補
-- そのものを補完メニューに出す設計）には、次の構造的な問題があった:
--
--   - 1回のキー入力につき最大 max_items+1 回もの dict.lookup() 呼び出しが
--     発生する（前方一致で最大 max_items 件の読みが見つかった場合）。
--   - SKKサーバーを有効にすると、"1" コマンドのハンドラ側で
--     google-japanese-input（既定値 "notfound"）が有効な限り、
--     ローカル辞書で見つからなかった読みのたびに SKKサーバーが
--     Google 日本語入力へのオンラインHTTPS問い合わせにフォールバックし、
--     1回で数秒単位の遅延になることがある（実機で発見。yaskkserv2 の
--     src/skk/yaskkserv2/dictionary_reader.rs の read_candidates() 参照。
--     google-suggest とは別の、独立した設定であることに注意）。
--   - 1回のキー入力で最大 max_items+1 回も踏むため、この「たまに重い」
--     経路に当たる確率が跳ね上がる。
--
-- skkeleton（denops/skkeleton/sources/skk_server.ts の
-- getCompletionResult()）は、ライブ補完では "4"（前方一致）だけを呼び、
-- 実際の変換候補（"1"）は選択・確定の段階まで一切取得しない設計だった。
-- これにより「1回のキー入力で最大1回の "4" のみ」に抑えられており、
-- "1" 由来の遅延（Googleフォールバック含む）をライブ補完中に踏むことが
-- そもそも無い。
--
-- 本ソースもこれに合わせ、v2 では **ライブ補完に出すのは読み一覧のみ**
-- とし、blink.cmp のメニューで読みを選ぶと `▽`/abbrev の読みがその読みに
-- 置き換わるだけ（henkan/state.lua の M.set_reading()）で、実際の変換候補
-- （▼）には進まない設計だった（これは Phase 2 で下記の通り拡張されている。
-- 以下は経緯として残す）。
--
-- 【Phase 2：実際の変換候補（漢字）も出す】（現在の設計）
-- v2 は「安全だが漢字が見えない」状態だった。Phase 2 では、個人辞書・
-- ローカル辞書・SKKサーバーのどれについても実際の変換候補まで取りに行き、
-- 見つかった読みには（読みではなく）漢字候補そのものを items として出す
-- （見つからない読みは従来通り読みのみのフォールバック項目にする）。
--
-- 個人辞書・ローカル辞書は M.lookup() がインメモリの同期処理なので、
-- 何件呼んでもコストは無視できる。危険なのは SKKサーバーへの "1" 呼び出し
-- で、これには2つの独立したリスクがある:
--
--   (1) 往復回数：読みの件数（最大 max_items 件）ぶん "1" を呼ぶと、
--       直列キュー（dict/skkserv.lua）を毎キー入力のたびに大量に消化する
--       ことになり、体感遅延に繋がる。
--   (2) notfound フォールバック：dict.lookup_prefix() が返す読み一覧は
--       個人辞書・ローカル辞書・SKKサーバーの「和集合」であり、SKKサーバー
--       自身の辞書には存在しない読み（ローカル辞書だけが知っている読み）
--       も混ざる。そういう読みに "1" を投げると skkserv 側で notfound と
--       なり、yaskkserv2 の Google 日本語入力フォールバックが発動して
--       数秒単位で詰まりうる（ファイル冒頭のリスク一覧の(2)そのもの）。
--
-- この2つを踏まないよう、dict.lookup_prefix() の第2戻り値
-- from_skkserv（SKKサーバー自身の "4" 応答に含まれていた読みだけの集合。
-- lua/skk/dict/init.lua 参照）を使い、SKKサーバーへ "1" を投げるのは
-- 「from_skkserv に入っている読みに限り、かつ件数上限
-- （blink.skkserv_candidate_limit、既定20件）まで」に絞る。上限を超えた
-- 分、および from_skkserv に無い読みは、個人辞書・ローカル辞書のみで
-- M.lookup() を呼ぶ（skip_skkserv=true。これは常にインメモリで安全）。
-- 個人辞書・ローカル辞書だけでも候補が見つからなかった読みは、v2 と同じ
-- 読みのみのフォールバック項目として出す。
--
-- require("skk").setup({ blink = { skkserv_candidates = false } }) で
-- SKKサーバーへの "1" 呼び出しそのものを完全に止められる（個人辞書・
-- ローカル辞書の候補のみになる。"4" による読み一覧の取得
-- （skip_skkserv）とは独立したスイッチ）。
--
-- 【使い方】blink.cmp の設定（sources.providers）に以下のように登録する:
--
--   sources = {
--     default = { "skk", "lsp", "path", "snippets", "buffer" },
--     providers = {
--       skk = {
--         name = "skk",
--         module = "skk.blink_source",
--         enabled = function()
--           local phase = require("skk.henkan.state").get_phase()
--           return phase == "midashi" or phase == "abbrev"
--         end,
--       },
--     },
--   }
--
-- `▽`/`▼` の表示に合わせて blink.cmp の補完メニューを show()/hide() する
-- には、henkan/state.lua が発火する User autocmd "SkkHenkanChanged" を
-- 使う（data.phase を見る）。設定例は README.md の「blink.cmp 連携」
-- セクションを参照。
--
-- 【設計上の重要な注意（skkeleton 用ソースとの決定的な違い）】
-- skkeleton は `▽`/`▼` を実バッファへの直接書き込みで表示するため、
-- skkeleton_source.lua は「実テキストの範囲を textEdit で置換する」方式
-- が使えた。一方 skk.nvim の `▽`/`▼` は extmark（仮想テキスト）表示で、
-- 実バッファには何も書き込まれていない。そのため同じ方式は使えない。
--
-- このソースでは textEdit を「今のカーソル位置への空挿入」（no-op）に
-- とどめ、実際の状態変更は execute() の中で henkan/state.lua に委譲する
-- （読みのみの項目なら M.set_reading()、変換候補そのものの項目なら
-- M.confirm_external()。詳細は execute() のコメント参照）。

---@module 'blink.cmp'
---@class blink.cmp.Source
local source = {}
source.__index = source

--- require("skk").setup({ blink = { ... } }) から lua/skk/init.lua 経由で
--- 差し込まれる設定。
---@type { max_items: integer, debug_timing: boolean, skip_skkserv: boolean, skkserv_candidates: boolean, skkserv_candidate_limit: integer }
local config = {
  max_items = 50,
  debug_timing = false,
  skip_skkserv = false,
  -- SKKサーバーへの "1"（実際の変換候補取得）を行うか。false なら
  -- 個人辞書・ローカル辞書の候補のみになる（"4" による読み一覧取得を
  -- 制御する skip_skkserv とは独立）。
  skkserv_candidates = true,
  -- skkserv_candidates=true のとき、実際に SKKサーバーへ "1" を投げる
  -- 読みの上限件数（dict.lookup_prefix() の from_skkserv に入っている
  -- 読みのうち、先頭からこの件数まで）。ファイル冒頭のコメント参照。
  skkserv_candidate_limit = 20,
}

---@param opts { max_items: integer?, debug_timing: boolean?, skip_skkserv: boolean?, skkserv_candidates: boolean?, skkserv_candidate_limit: integer? }|nil
function source.setup(opts)
  opts = opts or {}
  if opts.max_items ~= nil then
    config.max_items = opts.max_items
  end
  if opts.debug_timing ~= nil then
    config.debug_timing = opts.debug_timing
  end
  if opts.skip_skkserv ~= nil then
    config.skip_skkserv = opts.skip_skkserv
  end
  if opts.skkserv_candidates ~= nil then
    config.skkserv_candidates = opts.skkserv_candidates
  end
  if opts.skkserv_candidate_limit ~= nil then
    config.skkserv_candidate_limit = opts.skkserv_candidate_limit
  end

  -- 【重要・実機で発見】blink.cmp のライブ補完メニューが見えている間、
  -- capture.lua 側の「▽/abbrevで<CR>・未対応キーが来たら確定して抜ける」
  -- という自動確定ロジックを止める。止めないと、ユーザーが blink.cmp の
  -- accept 等に割り当てているキー（実機の設定では既定の <C-y> ではなく
  -- <CR> だった）に対して、blink.cmp 自身のキーマップと skk.nvim 側の
  -- 自動確定が二重に反応し、選択直後の読みが実バッファへ本当に挿入
  -- されたうえで▽状態も終了してしまう不具合があった。
  --
  -- どのキーが blink.cmp のどの操作に割り当てられているかはユーザーの
  -- keymap 設定次第で分からないため、特定のキーを決め打ちで判定するのは
  -- やめ、blink.cmp 自身の公開API `is_visible()`（メニュー or ゴースト
  -- テキストが見えているか）で判定する。
  require("skk.capture").set_passthrough_guard(function(_key)
    local ok, blink = pcall(require, "blink.cmp")
    if not ok then
      return false
    end
    return blink.is_visible()
  end)
end

function source.new()
  return setmetatable({}, source)
end

--- skk.nvim は SkkHenkanChanged autocmd で表示/非表示を通知するため、
--- 特定の trigger_characters は不要（skkeleton_source.lua と同じ考え方）。
function source:get_trigger_characters()
  return {}
end

function source:get_completions(_, callback)
  local henkan_state = require("skk.henkan.state")
  local dict = require("skk.dict")

  -- abbrev モード（"/" 開始、見出しがASCII文字列そのものになる）も
  -- 対象にする（実機で発見：以前は "midashi" 限定にしていたため、
  -- abbrev モードで候補ウィンドウが一切出ない不具合があった）。
  local phase = henkan_state.get_phase()
  if phase ~= "midashi" and phase ~= "abbrev" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return function() end
  end

  local reading = henkan_state.current_reading()
  if not reading or reading == "" then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  -- 【暫定の計測ログ】require("skk").setup({ blink = { debug_timing = true } })
  -- で有効化すると、この get_completions() 1回あたりの所要時間を
  -- vim.notify() に出す。
  local t_start = config.debug_timing and vim.loop.hrtime() or nil

  -- 送りありの前方一致補完は現時点で提供していない（dict.lookup_prefix()
  -- の設計を参照。プロトコル・実用上の理由で okuri-nasi のみに絞っている）。
  --
  -- 【設計 Phase 2】ここで取得するのは「読み一覧」（"4" コマンド相当）＋
  -- SKKサーバー自身の "4" 応答に含まれていた読みの集合（from_skkserv）。
  -- 各読みの実際の変換候補は、この後の items 構築ループで
  -- from_skkserv を見ながら件数上限つきで取得する（ファイル冒頭の設計
  -- 方針コメント参照）。
  local ok, readings, from_skkserv = pcall(dict.lookup_prefix, reading, false, config.max_items, config.skip_skkserv)
  from_skkserv = (ok and from_skkserv) or {}

  if t_start then
    local elapsed_ms = (vim.loop.hrtime() - t_start) / 1e6
    vim.schedule(function()
      vim.notify(
        string.format(
          "[skk.nvim timing] reading=%s readings=%d lookup_prefix=%.1fms",
          reading,
          (ok and readings) and #readings or 0,
          elapsed_ms
        )
      )
    end)
  end

  if not ok or not readings or #readings == 0 then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  -- 【textEdit について】上部のコメント参照。実際には何も編集しない
  -- （newText=""、range は今のカーソル位置ぴったりのゼロ幅）no-op にし、
  -- 実際の状態変更（読みの置き換え）は execute() に委譲する。
  --
  -- 【重要・実機で発見】range の計算はコマンドラインモードかどうかで
  -- 分岐させる必要がある。skk.nvim の enter_key は挿入モードだけでなく
  -- コマンドラインモード（単語登録UIの vim.fn.input() 等）にもマップして
  -- いるため、コマンドラインモード中に ▽ 変換が行われることがある。
  -- blink.cmp 自身の trigger/context.lua は「コマンドラインモードでは
  -- 行番号は常に 0（vim.fn.getcmdline() 相当）」という前提を置いており
  -- （context.get_cursor()/get_line() 参照）、ここで通常バッファの行番号
  -- （nvim_win_get_cursor(0) の行）をそのまま使うと、後続の候補プレビュー
  -- 処理（accept/preview.lua 等）が「Cannot get line number N in cmdline
  -- mode. Only 0 is supported」という assert エラーで落ちる（実機で確認）。
  local is_cmdline = vim.api.nvim_get_mode().mode == "c"
  local row0, col
  if is_cmdline then
    row0 = 0
    col = vim.fn.getcmdpos() - 1
  else
    local win = vim.api.nvim_win_get_cursor(0)
    row0 = win[1] - 1
    col = win[2]
  end
  local range = {
    start = { line = row0, character = col },
    ["end"] = { line = row0, character = col },
  }

  local kind = require("blink.cmp.types").CompletionItemKind.Text

  -- 【重要・実機で発見】blink.cmp 本体は、どのソースの候補であっても
  -- 一律に「実バッファのカーソル位置から独自に抽出した『キーワード』」を
  -- 問い合わせ文字列として、各候補の filterText（無ければ label）に対して
  -- ファジーマッチをかける（completion/list.lua の list.fuzzy() 参照）。
  -- これは is_incomplete_forward/backward の指定に関わらず必ず行われ、
  -- ソース側でバイパスする公式な手段は今のところ無い。
  --
  -- このキーワード抽出（fuzzy/rust/keyword.rs の BACKWARD_REGEX =
  -- `[\p{L}0-9_][\p{L}0-9_-]*$`）は Unicode の「文字」カテゴリを対象に
  -- しており、漢字も対象に含まれる。skk.nvim の ▽/▼ は extmark（仮想
  -- テキスト）表示で実バッファは変化しないため、カーソル直前に実テキスト
  -- として漢字や英数字が続いていると、それが丸ごと「キーワード」として
  -- 抽出されてしまう。抽出された「漢字」等の文字列と、こちらが返す
  -- 読み（例: "かん"）はほぼ一致しないため、フィルタで全滅し、候補
  -- ウィンドウ自体が開かなくなる（間に半角スペースを挟むと、そこで
  -- キーワードが空文字列になり単に全件通過するだけなので症状が出ない）。
  --
  -- 対策として、blink.cmp が実際に抽出するのと同じ関数
  -- （blink.cmp.fuzzy.get_keyword_range()、blink.cmp.config の
  -- completion.keyword.range 設定を使用）をこちらからも呼んで、
  -- blink.cmp が抽出するはずの文字列を先読みし、filterText の先頭に
  -- そのまま前置する。こうすれば、blink.cmp が何を抽出しようと、それは
  -- 常に filterText の先頭一致になるためフィルタで弾かれない。
  -- 【注意】blink.cmp の非公開に近い内部実装（fuzzy.get_keyword_range）に
  -- 依存しているため、blink.cmp のアップデートで壊れる可能性がある。
  -- 呼び出しは pcall で保護し、失敗時は空文字列にフォールバックする
  -- （その場合はこの不具合が再発するだけで、他の動作には影響しない）。
  local real_keyword = ""
  do
    local ok_kw, kw = pcall(function()
      local fuzzy_mod = require("blink.cmp.fuzzy")
      local blink_config = require("blink.cmp.config")
      local line = is_cmdline and vim.fn.getcmdline() or vim.api.nvim_get_current_line()
      local kw_start, kw_end = fuzzy_mod.get_keyword_range(line, col, blink_config.completion.keyword.range)
      return line:sub(kw_start + 1, kw_end)
    end)
    if ok_kw and type(kw) == "string" then
      real_keyword = kw
    end
  end

  -- 【Phase 2】各読みについて実際の変換候補を取りに行く。SKKサーバーへの
  -- "1" は、from_skkserv に入っている（＝SKKサーバー自身が "4" で存在を
  -- 表明した）読みに限り、かつ実際に呼んだ回数が
  -- config.skkserv_candidate_limit に達するまでだけ許可する（ファイル
  -- 冒頭の設計方針コメント参照）。それ以外の読みは個人辞書・ローカル
  -- 辞書のみで M.lookup() を呼ぶ（常にインメモリで安全）。
  local t_after_prefix = t_start and vim.loop.hrtime() or nil
  local items = {}
  local item_rank = 0
  local skkserv_calls = 0
  for _, full_reading in ipairs(readings) do
    local use_skkserv = config.skkserv_candidates and from_skkserv[full_reading] == true
    if use_skkserv then
      if skkserv_calls >= config.skkserv_candidate_limit then
        use_skkserv = false
      else
        skkserv_calls = skkserv_calls + 1
      end
    end

    local ok_c, candidates = pcall(dict.lookup, full_reading, false, not use_skkserv)
    if ok_c and candidates and #candidates > 0 then
      for _, cand in ipairs(candidates) do
        item_rank = item_rank + 1
        table.insert(items, {
          -- 変換候補（漢字）そのものを表示する。
          label = cand.word,
          labelDetails = { description = full_reading },
          filterText = real_keyword .. reading,
          sortText = string.format("%010d", item_rank),
          kind = kind,
          textEdit = { range = range, newText = "" },
          data = { reading = full_reading, word = cand.word, annotation = cand.annotation },
        })
      end
    else
      -- 候補が1件も見つからなかった読みは、v2 と同じ「読みのみ」の
      -- フォールバック項目にする（選ぶと読みが置き換わるだけで▽のまま。
      -- execute() 参照）。
      item_rank = item_rank + 1
      table.insert(items, {
        label = full_reading,
        filterText = real_keyword .. reading,
        sortText = string.format("%010d", item_rank),
        kind = kind,
        textEdit = { range = range, newText = "" },
        data = { reading = full_reading },
      })
    end
  end

  if t_start then
    local t_end = vim.loop.hrtime()
    vim.schedule(function()
      vim.notify(
        string.format(
          "[skk.nvim timing] reading=%s readings=%d items=%d skkserv_calls=%d candidate_loop=%.1fms total=%.1fms",
          reading,
          #readings,
          #items,
          skkserv_calls,
          (t_end - t_after_prefix) / 1e6,
          (t_end - t_start) / 1e6
        )
      )
    end)
  end

  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  return function() end
end

--- resolve() は候補選択時のドキュメント（annotation）表示にのみ使う。
--- label 等の書き換えは行わない（blink.cmp のソース契約上、resolve() は
--- documentation の遅延取得を主眼としており、必須ではない付加情報。
--- annotation を持たない項目（読みのみのフォールバック項目、または
--- 辞書側でannotationが無い候補）ではそのまま何もせず返す）。
function source:resolve(item, callback)
  local annotation = item.data and item.data.annotation
  if annotation then
    item.documentation = { kind = "plaintext", value = annotation }
  end
  callback(item)
end

--- 【重要】blink.cmp の accept パイプラインでは、textEdit の適用は
--- execute() に渡される第4引数 default_implementation を自分で
--- 呼び出さない限り一切実行されない（呼び忘れると「確定してもバッファに
--- 反映されない」不具合になる。nvim-config-blink-skkeleton での実例で
--- 確認済み）。このソースの textEdit は no-op（上部コメント参照）なので
--- 実質的には何もしないが、契約上必ず呼ぶ。
--- 【Phase 2】item.data.word が入っている（＝実際の変換候補が選ばれた）
--- 場合は henkan/state.lua の M.confirm_external() に委譲し、その場で
--- 個人辞書への学習・実テキストの挿入まで一気に行う（▽/▼状態は終了する。
--- v1 と同じ挙動）。word が無い（＝候補が見つからず読みのみの
--- フォールバック項目だった）場合は、従来通り M.set_reading() で読みの
--- 置き換えに留める（▽のまま。ユーザーは <SPC> で ▼ に進む）。
function source:execute(_, item, callback, default_implementation)
  default_implementation()

  local data = item.data or {}
  local henkan_state = require("skk.henkan.state")
  if data.reading and data.word then
    henkan_state.confirm_external(data.reading, false, data.word, data.annotation)
  elseif data.reading then
    henkan_state.set_reading(data.reading)
  end

  callback()
end

return source
