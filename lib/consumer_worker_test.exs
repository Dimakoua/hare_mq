defmodule HareMq.Worker.ConsumerTest do
  use ExUnit.Case
  alias HareMq.Worker.Consumer
  alias HareMq.Connection

  @config [
    queue_name: "test_queue_name",
    routing_key: "test_routing_key",
    exchange: "test_routing_key",
    prefetch_count: 1,
    consumer_name: :test_consumer_name
  ]

  setup do
    Application.put_env(:hare_mq, :amqp, %{url: "amqp://guest:guest@localhost"})
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})
    # Start the Registry for tests
    start_supervised!({Registry, keys: :unique, name: :consumers})
    :ok
  end

  @tag :capture_log
  test "starts with correct configuration" do
    consume_fn = fn _msg -> :ok end
    {:ok, _pid} = Connection.start_link(nil)
    {:ok, pid} = Consumer.start_link(config: @config, consume: consume_fn)
    assert Process.alive?(pid)
    assert :ok = GenServer.stop(pid)
  end
end
