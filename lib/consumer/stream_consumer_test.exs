defmodule HareMq.StreamConsumerTest do
  use HareMq.TestCase
  alias HareMq.{Configuration, Connection}

  @test_message "stream test message"

  # Publishes to the default exchange so the stream queue receives messages
  # without requiring an explicit binding (stream consumers don't bind queues).
  defmodule TestStreamPublisher do
    use HareMq.Publisher,
      exchange: nil,
      routing_key: "test_stream_queue_1"
  end

  defmodule TestStreamConsumer do
    use HareMq.Consumer,
      queue_name: "test_stream_queue_1",
      stream: true,
      stream_offset: "first"

    def consume(message) do
      case :global.whereis_name(:stream_consumer_test_receiver) do
        pid when is_pid(pid) -> send(pid, {:consumed, message})
        _ -> :ok
      end

      :ok
    end
  end

  # Returns :error to verify that stream consumers always ack (no retry).
  defmodule TestStreamErrorConsumer do
    use HareMq.Consumer,
      queue_name: "test_stream_error_queue_1",
      stream: true,
      stream_offset: "first"

    def consume(_message) do
      case :global.whereis_name(:stream_error_test_receiver) do
        pid when is_pid(pid) -> send(pid, :error_consume_called)
        _ -> :ok
      end

      :error
    end
  end

  defmodule TestStreamPublisherError do
    use HareMq.Publisher,
      exchange: nil,
      routing_key: "test_stream_error_queue_1"
  end

  setup do
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})
    stop_global(HareMq.Connection)
    {:ok, _} = Connection.start_link([])

    on_exit(fn ->
      stop_global(HareMq.Connection)
      stop_global(TestStreamConsumer)
      stop_global(TestStreamErrorConsumer)
      stop_global(TestStreamPublisher)
      stop_global(TestStreamPublisherError)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Unit tests — no broker interaction
  # ---------------------------------------------------------------------------

  describe "Configuration.get_queue_configuration/1 stream fields" do
    test "defaults stream to false and stream_offset to 'next'" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue"
        )

      assert config.stream == false
      assert config.stream_offset == "next"
    end

    test "stream: true is stored correctly" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true
        )

      assert config.stream == true
      assert config.stream_offset == "next"
    end

    test "accepts string stream_offset values" do
      for offset <- ["first", "last", "next"] do
        config =
          Configuration.get_queue_configuration(
            channel: nil,
            consume_fn: fn _ -> :ok end,
            name: "my_queue",
            stream: true,
            stream_offset: offset
          )

        assert config.stream_offset == offset
      end
    end

    test "accepts integer stream_offset" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true,
          stream_offset: 42
        )

      assert config.stream_offset == 42
    end

    test "accepts DateTime stream_offset" do
      dt = ~U[2024-01-01 00:00:00Z]

      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true,
          stream_offset: dt
        )

      assert config.stream_offset == dt
    end

    test "non-stream config still builds delay and dead queue names" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "orders"
        )

      assert config.delay_queue_name == "orders.delay"
      assert config.dead_queue_name == "orders.dead"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests — require a running RabbitMQ with rabbitmq_stream enabled
  # ---------------------------------------------------------------------------

  @tag :capture_log
  test "stream consumer starts and receives published messages" do
    :global.register_name(:stream_consumer_test_receiver, self())

    {:ok, cons_pid} = TestStreamConsumer.start_link()
    {:ok, pub_pid} = TestStreamPublisher.start_link()

    wait_until(fn -> TestStreamPublisher.publish_message(@test_message) == :ok end)

    assert_receive {:consumed, @test_message}, 5_000

    :ok = GenServer.stop(pub_pid)
    :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_consumer_test_receiver)
  end

  @tag :capture_log
  test "stream consumer acks messages even when consume/1 returns :error (no retry)" do
    :global.register_name(:stream_error_test_receiver, self())

    {:ok, cons_pid} = TestStreamErrorConsumer.start_link()
    {:ok, pub_pid} = TestStreamPublisherError.start_link()

    wait_until(fn -> TestStreamPublisherError.publish_message(@test_message) == :ok end)

    # consume/1 is called exactly once — ack advances the credit window
    assert_receive :error_consume_called, 5_000

    # If the message were retried/redelivered, a second notification would arrive
    refute_receive :error_consume_called, 500

    :ok = GenServer.stop(pub_pid)
    :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_error_test_receiver)
  end

  @tag :capture_log
  test "stream consumer with stream_offset: 'first' replays existing messages" do
    :global.register_name(:stream_consumer_test_receiver, self())

    # First: connect publisher and write a message before the consumer starts
    {:ok, pub_pid} = TestStreamPublisher.start_link()
    wait_until(fn -> TestStreamPublisher.publish_message(@test_message) == :ok end)
    :ok = GenServer.stop(pub_pid)
    stop_global(TestStreamPublisher)

    # Now start the consumer — stream_offset: "first" should replay the message
    {:ok, cons_pid} = TestStreamConsumer.start_link()

    assert_receive {:consumed, @test_message}, 5_000

    :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_consumer_test_receiver)
  end
end
