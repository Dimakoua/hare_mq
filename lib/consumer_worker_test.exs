defmodule HareMq.Worker.ConsumerTest do
  use HareMq.TestCase
  alias HareMq.Worker.Consumer
  alias HareMq.Connection
  @test_message "publishing and consuming messages test"

  # Define a simple Publisher module
  defmodule TestPublisher do
    use HareMq.Publisher, exchange: "test_routing_key_1", routing_key: "test_routing_key_1"
  end

  # Define a simple Consumer module
  defmodule TestConsumer do
    @test_message "publishing and consuming messages test"
    use HareMq.Consumer,
      queue_name: "test_queue_name_1",
      routing_key: "test_routing_key_1",
      exchange: "test_routing_key_1"

    def consume(message) do
      if :ok !== wait_until(fn -> message === @test_message end) do
        GenServer.stop(self())
      else
        :ok
      end
    end
  end

  @config [
    queue_name: "test_queue_name_1",
    routing_key: "test_routing_key_1",
    exchange: "test_routing_key_1",
    prefetch_count: 1,
    consumer_name: :test_consumer_name
  ]

  setup do
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})
    # Start the Registry for tests
    start_supervised!({Registry, keys: :unique, name: :consumers})
    {:ok, _pid} = Connection.start_link(nil)

    :ok
  end

  @tag :capture_log
  test "starts with correct configuration" do
    consume_fn = fn _msg -> :ok end
    {:ok, pid} = Consumer.start_link(config: @config, consume: consume_fn)
    assert Process.alive?(pid)
    assert :ok = GenServer.stop(pid)
  end

  test "publishing and consuming messages" do
    {:ok, pub_pid} = TestPublisher.start_link()

    wait_until(fn -> :ok = TestPublisher.publish_message(@test_message) end)

    {:ok, cons_pid} =
      TestConsumer.start_link(
        config: %{
          consumer_name: "test_consumer",
          queue_name: "test_queue",
          exchange: "test_exchange"
        },
        consume: &TestConsumer.consume/1
      )

    Process.sleep(300)

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  end
end
