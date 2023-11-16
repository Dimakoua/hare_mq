defmodule HareMq.ConnectionTest do
  use ExUnit.Case, async: false
  alias HareMq.Connection
  doctest HareMq.Connection

  test "get_connection" do
    assert {:ok, %AMQP.Connection{}} = Connection.get_connection()
  end

  test "close_connection" do
    assert {:ok, %AMQP.Connection{}} = Connection.close_connection()
  end
end
