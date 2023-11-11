defmodule HareMqTest do
  use ExUnit.Case
  doctest HareMq

  test "greets the world" do
    assert HareMq.hello() == :world
  end
end
