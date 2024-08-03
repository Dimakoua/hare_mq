defmodule HareMq.ConnectionTest do
  use HareMq.TestCase
  alias HareMq.Connection

  setup do
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})
  end

  test "successfully connects and gets connection" do
    {:ok, _pid} = Connection.start_link(nil)
    assert wait_until(fn -> {:ok, %AMQP.Connection{}} = Connection.get_connection() end)
  end

  test "fails to get connection when not connected" do
    assert {:error, :not_connected} = Connection.get_connection()
  end

  test "successfully closes the connection" do
    {:ok, _pid} = Connection.start_link(nil)

    assert wait_until(fn -> {:ok, %AMQP.Connection{}} = Connection.get_connection() end)

    # Close the connection
    assert wait_until(fn -> {:ok, %AMQP.Connection{}} = Connection.close_connection() end)

    # Verify that the connection is indeed closed
    assert wait_until(fn -> {:error, :not_connected} = Connection.get_connection() end)
  end

  test "fails to close connection when not connected" do
    {:ok, _pid} = Connection.start_link(nil)

    assert wait_until(fn -> {:ok, %AMQP.Connection{}} = Connection.close_connection() end)
    assert wait_until(fn -> {:error, :not_connected} = Connection.close_connection() end)
  end
end
