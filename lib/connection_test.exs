defmodule HareMq.ConnectionTest do
  use ExUnit.Case
  alias HareMq.Connection

  setup do
    Application.put_env(:hare_mq, :amqp, %{url: "amqp://guest:guest@localhost"})
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})
  end

  test "successfully connects and gets connection" do
    {:ok, _pid} = Connection.start_link(nil)

    # Give some time to establish the connection
    Process.sleep(100)

    assert {:ok, %AMQP.Connection{}} = Connection.get_connection()
  end

  test "fails to get connection when not connected" do
    assert {:error, :not_connected} = Connection.get_connection()
  end

  test "successfully closes the connection" do
    {:ok, _pid} = Connection.start_link(nil)

    # Give some time to establish the connection
    Process.sleep(100)

    assert {:ok, %AMQP.Connection{}} = Connection.get_connection()

    # Close the connection
    assert {:ok, %AMQP.Connection{}} = Connection.close_connection()

    # Wait a bit to ensure the connection has time to close and the state to update
    Process.sleep(100)

    # Verify that the connection is indeed closed
    assert {:error, :not_connected} = Connection.get_connection()
  end

  test "fails to close connection when not connected" do
    {:ok, _pid} = Connection.start_link(nil)

    assert {:ok, %AMQP.Connection{}} = Connection.close_connection()
    assert {:error, :not_connected} = Connection.close_connection()
  end
end
