-- lua/skk/health.lua
--
-- :checkhealth skk 用のヘルスチェック。
-- skk.nvim 本体の動作には関与しない（:checkhealth 実行時にのみ vim が
-- 読み込む）。インストール後にユーザー自身で、Neovimのバージョン・
-- setup() 実行状況・任意の依存（blink.cmp）・ローカル辞書の読み込み
-- 結果・SKKサーバーの疎通を診断できるようにするためのもの。
--
-- 【設計方針】診断はすべて既存の公開API（require("skk.dict") 等）経由で
-- 行い、内部の private な状態には触れない。SKKサーバーの疎通確認は
-- :SkkCheckSkkserv コマンド（lua/skk/init.lua）と同じく dict.skkserv_version()
-- を同期的に呼ぶ（:checkhealth はユーザーが明示的に実行する診断コマンド
-- なので、多少の待ち時間が生じても問題にならない）。

local M = {}

--- Neovim のバージョンが要件（0.10 以上）を満たしているか。
---@return boolean
local function has_min_nvim_version()
  local v = vim.version()
  if v.major > 0 then
    return true
  end
  return v.minor >= 10
end

function M.check()
  vim.health.start("skk.nvim")

  -- Neovim バージョン -----------------------------------------------------
  local v = vim.version()
  local version_str = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if has_min_nvim_version() then
    vim.health.ok("Neovim " .. version_str .. "（要件: 0.10 以上）")
  else
    vim.health.error(
      "Neovim "
        .. version_str
        .. " は要件（0.10 以上）を満たしていません。"
        .. "vim.on_key() の空文字列 return によるキー消費、vim.schedule、extmark 等、"
        .. "0.10 未満では前提の機能が使えません。"
    )
  end

  -- setup() が呼ばれているか -----------------------------------------------
  -- 【判定方法】require("skk") 自体は setup() 前でも require できてしまう
  -- ため、setup() 実行の有無を直接示すフラグは持っていない。setup() は
  -- 必ず dict.set_user_dict_path() -> user_dict.load() を呼ぶので、
  -- 個人辞書のパスが設定済みかどうかで代用する。
  local user_dict = require("skk.dict.user_dict")
  local user_dict_path = user_dict.path()
  if user_dict_path then
    vim.health.ok('require("skk").setup() は実行済みです（個人辞書: ' .. user_dict_path .. "）")
  else
    vim.health.warn(
      'require("skk").setup({...}) がまだ実行されていないようです。'
        .. "lazy.nvim 等の config/opts 内で呼び出してください（README「インストール」参照）。"
    )
  end

  -- blink.cmp（任意の依存） ------------------------------------------------
  if pcall(require, "blink.cmp") then
    vim.health.ok(
      "blink.cmp が検出されました（lua/skk/blink_source.lua によるネイティブソース統合が利用できます）"
    )
  else
    vim.health.info(
      "blink.cmp は検出されませんでした（任意の依存です。blink.cmp によるライブ補完を使わない場合は無視して構いません）"
    )
  end

  -- ローカル辞書 -----------------------------------------------------------
  local dict = require("skk.dict")
  local loaded = dict.loaded_dictionaries()
  if #loaded == 0 then
    vim.health.info(
      "setup({ dictionaries = {...} }) によるローカル辞書は読み込まれていません"
        .. "（個人辞書・skkservのみで運用中、または setup() が未実行の可能性があります）"
    )
  else
    for _, info in ipairs(loaded) do
      local label = info.path or info.name
      if info.ok then
        vim.health.ok(string.format("辞書 %s を読み込み済みです（%s）", label, info.loaded_at))
      else
        vim.health.error(
          string.format(
            "辞書 %s の読み込みに失敗しました（%s）: %s",
            label,
            info.loaded_at,
            tostring(info.err)
          )
        )
      end
    end
  end

  -- SKKサーバー -------------------------------------------------------------
  local skk = require("skk")
  local skkserv_opts = skk.get_skkserv_opts()
  if not skkserv_opts then
    vim.health.info(
      "skkserv は設定されていません（setup({ skkserv = {...} }) 参照。任意機能なので未設定でも問題ありません）"
    )
  else
    local label = string.format("%s:%s", skkserv_opts.host, tostring(skkserv_opts.port or 1178))
    local timeout_ms = skkserv_opts.check_connection_timeout_ms or 2000
    local ok, version = pcall(dict.skkserv_version, timeout_ms)
    if ok and version then
      vim.health.ok("skkserv (" .. label .. ") に接続できました（応答: " .. version .. "）")
    else
      local detail = dict.skkserv_last_connect_error()
      vim.health.warn(
        "skkserv ("
          .. label
          .. ") に接続できませんでした（status="
          .. dict.skkserv_status()
          .. (detail and (", error=" .. tostring(detail)) or "")
          .. "）。サーバーを起動していない・まだ設定を反映していない等であれば、この警告は無視して構いません。"
      )
    end
  end
end

return M
