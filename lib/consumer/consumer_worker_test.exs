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
    use HareMq.Consumer,
      queue_name: "test_queue_name_1",
      routing_key: "test_routing_key_1",
      exchange: "test_routing_key_1"

    def consume(message) do
      case :global.whereis_name(:consumer_worker_test_receiver) do
        pid when is_pid(pid) -> send(pid, {:consumed, message})
        _ -> :ok
      end

      :ok
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
    :global.register_name(:consumer_worker_test_receiver, self())

    {:ok, pub_pid} = TestPublisher.start_link()
    {:ok, cons_pid} = TestConsumer.start_link()

    wait_until(fn -> TestPublisher.publish_message(@test_message) == :ok end)

    assert_receive {:consumed, @test_message}, 5_000

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:consumer_worker_test_receiver)
  end
end
