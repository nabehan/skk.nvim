local Context = require("skk.context")

describe("Context", function()
  it("starts empty", function()
    local context = Context.new()
    assert.are.equals("", context.fixed)
    assert.are.equals("", context.buffer)
  end)
end)
