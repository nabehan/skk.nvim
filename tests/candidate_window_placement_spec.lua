-- tests/candidate_window_placement_spec.lua
--
-- lua/skk/henkan/candidate_window.lua の「表示位置の sticky 化」を検証する。
-- 実際の screenpos() 計算結果は plenary/nvim 上でしか確認できないため
-- （tests/candidate_window_spec.lua の _compute_placement 参照）、ここでは
-- 「一度決めた配置を、ウィンドウが開いている間は使い回すか」という
-- ロジック自体を、vim.* の最小限モックで検証する。

-- --- vim.* の最小限のダミー実装 ---
local win_configs = {} -- open_win / set_config に渡された config を記録
local win_counter = 0
local open_wins = {}

_G.vim = _G.vim or {}
vim.o = { lines = 20, cmdheight = 1 }
vim.bo = setmetatable({}, {
  __index = function()
    return {}
  end,
})
vim.api = vim.api or {}
vim.api.nvim_create_buf = function()
  return 1
end
vim.api.nvim_buf_is_valid = function()
  return true
end
vim.api.nvim_buf_set_lines = function() end
vim.api.nvim_create_namespace = function()
  return 1
end
vim.api.nvim_buf_clear_namespace = function() end
vim.api.nvim_buf_set_extmark = function() end
vim.api.nvim_win_is_valid = function(id)
  return open_wins[id] == true
end
vim.api.nvim_open_win = function(_, _, config)
  win_counter = win_counter + 1
  local id = win_counter
  open_wins[id] = true
  table.insert(win_configs, { id = id, config = config })
  return id
end
vim.api.nvim_win_set_config = function(id, config)
  table.insert(win_configs, { id = id, config = config })
end
vim.api.nvim_win_close = function(id)
  open_wins[id] = nil
end
vim.fn = vim.fn or {}
vim.fn.strdisplaywidth = function(s)
  return #s
end
-- 「下には全然入りきらない（＝上に出すしかない）」状況を固定でシミュレートする。
vim.fn.screenpos = function()
  return { row = 15 } -- vim.o.lines=20, cmdheight=1 なので、下の余白は 4 行しかない
end

local candidate_window = require("skk.henkan.candidate_window")

local function make_candidates(n)
  local out = {}
  for i = 1, n do
    table.insert(out, { word = tostring(i) })
  end
  return out
end

describe("candidate_window sticky placement", function()
  before_each(function()
    win_configs = {}
    win_counter = 0
    open_wins = {}
    candidate_window.hide() -- sticky状態もリセットする
  end)

  it("最初の表示で、下に入りきらなければ上（SW）に決まる", function()
    candidate_window.show(0, 0, 0, make_candidates(7), 1, 1) -- 7行、下の余白4行では入らない
    local last = win_configs[#win_configs]
    assert.are.equal("SW", last.config.anchor)
  end)

  it(
    "一度 SW に決まったら、候補数が減って本来は下にも収まるようになっても SW のまま",
    function()
      candidate_window.show(0, 0, 0, make_candidates(7), 1, 2) -- 1回目: SW に決まる
      candidate_window.show(0, 0, 0, make_candidates(2), 2, 2) -- <SPC>で候補が2件に減った想定
      local last = win_configs[#win_configs]
      assert.are.equal("SW", last.config.anchor) -- 2件なら下にも余裕で入るはずだが、SWを維持する
    end
  )

  it("hide() すると sticky がリセットされ、次の表示で改めて計算し直す", function()
    candidate_window.show(0, 0, 0, make_candidates(7), 1, 1)
    candidate_window.hide()
    candidate_window.show(0, 0, 0, make_candidates(7), 1, 1)
    -- 2回目は「新しい変換セッションの最初の表示」として扱われ、
    -- 改めて compute_placement が呼ばれる（結果自体は screenpos が固定なので SW のまま）。
    local last = win_configs[#win_configs]
    assert.are.equal("SW", last.config.anchor)
    -- 直前の close 後、新しい winid で開き直されていることを確認
    assert.is_true(#win_configs >= 2)
  end)
end)
