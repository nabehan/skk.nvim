-- tests/encoding_spec.lua
--
-- lua/skk/encoding.lua のテスト。
--
-- 【注意】このファイルの本体は vim.fn.iconv() に依存しており、実際の
-- 文字コード変換（例: euc-jp -> utf-8）はこの Lua サンドボックスには
-- 実 Neovim が無いため検証できない。ここでは vim.* を呼ばずに済む
-- 経路（from == to の恒等変換）だけを確認する。実際の iconv 変換は
-- plenary/nvim 上での動作確認が必要。

local encoding = require("skk.encoding")

describe("encoding.convert (identity path, no vim.fn.iconv 呼び出し)", function()
  it("from と to が同じなら iconv を呼ばずにそのまま返す", function()
    assert.are.equal("あいうえお", encoding.convert("あいうえお", "utf-8", "utf-8"))
  end)
end)

describe("encoding.to_utf8 (identity path)", function()
  it("from が utf-8 ならそのまま返す", function()
    assert.are.equal("かんじ", encoding.to_utf8("かんじ", "utf-8"))
  end)
end)
