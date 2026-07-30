-- tests/file_source_spec.lua
--
-- lua/skk/dict/file_source.lua のテスト。
--
-- 【注意】実際の文字コード変換（euc-jp -> utf-8 等）は vim.fn.iconv() に
-- 依存するため、この Lua サンドボックスには実 Neovim が無い前提だと
-- 検証できない。ここでは file_encoding="utf-8"（encoding.convert の
-- 恒等変換パス、iconv を呼ばない）を使い、ファイル読み込み＋パースの
-- 一連の流れを実ファイルで検証する。実際の euc-jp 変換は plenary/nvim
-- 上での動作確認が必要。

local file_source = require("skk.dict.file_source")

local function write_temp_file(content)
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

describe("file_source.load (utf-8, iconv を経由しない恒等変換パス)", function()
  it("存在するファイルを読み込んでパースできる", function()
    local path = write_temp_file(table.concat({
      "かんじ /漢字/幹事/",
      ";; okuri-ari entries.",
      "うごk /動/",
    }, "\n"))

    local dict, err = file_source.load(path, "utf-8")
    os.remove(path)

    assert.is_nil(err)
    assert.are.equal("漢字", dict.okuri_nasi["かんじ"][1])
    assert.are.equal("動", dict.okuri_ari["うごk"][1])
  end)

  it("存在しないファイルはエラーを返す", function()
    local dict, err = file_source.load("/tmp/skk_nvim_test_no_such_file.txt", "utf-8")
    assert.is_nil(dict)
    assert.is_not_nil(err)
  end)
end)
