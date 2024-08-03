defmodule HareMq.PublisherTest do
  use ExUnit.Case
  alias HareMq.Connection

  defmodule TestPublisher do
    use HareMq.Publisher, exchange: "test_routing_key", routing_key: "test_routing_key"
  end

  setup do
    # Set necessary application environment configurations for real RabbitMQ connection
    Application.put_env(:hare_mq, :amqp, %{url: "amqp://guest:guest@localhost"})
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})

    Connection.start_link(nil)
    :ok
  end

  describe "start_link/1" do
    test "starts the GenServer and connects to RabbitMQ" do
      {:ok, pid} = TestPublisher.start_link()
      # Verify the GenServer has a channel connected
      assert {:ok, %AMQP.Channel{}} = TestPublisher.get_channel()
      GenServer.stop(pid)
    end
  end

  describe "publish_message/1" do
    test "successfully publishes a binary message" do
      message = "binary message"
      {:ok, pid} = TestPublisher.start_link()
      assert :ok = TestPublisher.publish_message(message)
      GenServer.stop(pid)
    end

    test "successfully publishes a message as a map" do
      message = %{key: "value"}
      {:ok, pid} = TestPublisher.start_link()
      assert :ok = TestPublisher.publish_message(message)
      GenServer.stop(pid)
    end
  end
end
