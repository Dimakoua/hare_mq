defmodule HareMq.Integration.StreamIntegrationTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.Test.RabbitMQManagement, as: Mgmt

  # ---- Test modules --------------------------------------------------------

  # Consumer that starts at "next" — only receives newly published messages
  defmodule StreamNextConsumer do
    use HareMq.Consumer,
      queue_name: "int_stream_next_q",
      routing_key: "int_stream_next_q",
      exchange: "int_stream_next_exchange",
      stream: true,
      stream_offset: "next"

    def consume(message) do
      case :global.whereis_name(:stream_next_receiver) do
        pid when is_pid(pid) -> send(pid, {:consumed, message})
        _ -> :ok
      end

      :ok
    end
  end

  # Consumer that starts at "first" — replays all stored messages
  defmodule StreamReplayConsumer do
    use HareMq.Consumer,
      queue_name: "int_stream_next_q",
      routing_key: "int_stream_next_q",
      exchange: "int_stream_next_exchange",
      stream: true,
      stream_offset: "first"

    def consume(message) do
      case :global.whereis_name(:stream_replay_receiver) do
        pid when is_pid(pid) -> send(pid, {:replayed, message})
        _ -> :ok
      end

      :ok
    end
  end

  # Consumer that always returns :error — verifies ack-on-error behaviour
  defmodule StreamErrorConsumer do
    use HareMq.Consumer,
      queue_name: "int_stream_error_q",
      routing_key: "int_stream_error_q",
      exchange: "int_stream_error_exchange",
      stream: true,
      stream_offset: "next"

    def consume(_message) do
      case :global.whereis_name(:stream_error_receiver) do
        pid when is_pid(pid) -> send(pid, :error_consume_called)
        _ -> :ok
      end

      :error
    end
  end

  defmodule StreamNextPublisher do
    use HareMq.Publisher,
      exchange: "int_stream_next_exchange",
      routing_key: "int_stream_next_q"
  end

  defmodule StreamErrorPublisher do
    use HareMq.Publisher,
      exchange: "int_stream_error_exchange",
      routing_key: "int_stream_error_q"
  end

  # ---- Queue names ---------------------------------------------------------

  @next_q "int_stream_next_q"
  @error_q "int_stream_error_q"

  # ---- Setup / teardown ----------------------------------------------------

  setup do
    Application.put_env(:hare_mq, :amqp, url: Mgmt.amqp_url())
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})

    for name <- [StreamNextConsumer, StreamReplayConsumer, StreamErrorConsumer,
                 StreamNextPublisher, StreamErrorPublisher, HareMq.Connection] do
      stop_global(name)
    end

    Process.sleep(150)

    Mgmt.delete_queue(@next_q)
    Mgmt.delete_queue(@error_q)

    stop_global(HareMq.Connection)
    {:ok, _} = Connection.start_link([])

    on_exit(fn ->
      for name <- [StreamNextConsumer, StreamReplayConsumer, StreamErrorConsumer,
                   StreamNextPublisher, StreamErrorPublisher, HareMq.Connection] do
        stop_global(name)
      end

      Process.sleep(150)
      Mgmt.delete_queue(@next_q)
      Mgmt.delete_queue(@error_q)
    end)

    :ok
  end

  # ---- Tests ---------------------------------------------------------------

  @tag :capture_log
  test "stream consumer receives message published after it connects" do
    :global.register_name(:stream_next_receiver, self())

    {:ok, cons_pid} = StreamNextConsumer.start_link()
    {:ok, pub_pid} = StreamNextPublisher.start_link()

    # Ensure the consumer has subscribed (stream_offset: "next") before publishing
    wait_until(fn -> match?({:ok, _}, StreamNextPublisher.get_channel()) end)
    wait_until(fn ->
      case GenServer.call({:global, StreamNextConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    StreamNextPublisher.publish_message("hello stream")

    assert_receive {:consumed, "hello stream"}, 5_000

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_next_receiver)
  end

  @tag :capture_log
  test "published message is recorded in stream queue (retention)" do
    {:ok, pub_pid} = StreamNextPublisher.start_link()
    {:ok, cons_pid} = StreamNextConsumer.start_link()

    assert :ok = Mgmt.wait_for_consumers(@next_q)
    wait_until(fn -> StreamNextPublisher.publish_message("count_test") == :ok end)

    # Stream queues retain messages — management API reflects the stored count
    assert :ok = Mgmt.wait_for_messages(@next_q, 1)

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "stream consumer with offset 'first' replays previously published messages" do
    :global.register_name(:stream_replay_receiver, self())

    # 1. Start publisher and a first consumer (offset: "next") — just to declare the queue
    {:ok, pub_pid} = StreamNextPublisher.start_link()
    {:ok, first_pid} = StreamNextConsumer.start_link()

    assert :ok = Mgmt.wait_for_consumers(@next_q)

    wait_until(fn -> StreamNextPublisher.publish_message("replay_msg_1") == :ok end)
    wait_until(fn -> StreamNextPublisher.publish_message("replay_msg_2") == :ok end)

    # Wait for the messages to be stored in the stream
    assert :ok = Mgmt.wait_for_messages(@next_q, 2)

    GenServer.stop(first_pid)
    GenServer.stop(pub_pid)

    # 2. Start a fresh consumer with offset: "first" — should replay from the beginning
    {:ok, replay_pid} = StreamReplayConsumer.start_link()

    assert_receive {:replayed, "replay_msg_1"}, 5_000
    assert_receive {:replayed, "replay_msg_2"}, 5_000

    GenServer.stop(replay_pid)
  after
    :global.unregister_name(:stream_replay_receiver)
  end

  @tag :capture_log
  test "stream consumer acks messages even when consume/1 returns :error" do
    :global.register_name(:stream_error_receiver, self())

    {:ok, cons_pid} = StreamErrorConsumer.start_link()
    {:ok, pub_pid} = StreamErrorPublisher.start_link()

    # Wait for consumer subscription before publishing (stream_offset: "next")
    wait_until(fn -> match?({:ok, _}, StreamErrorPublisher.get_channel()) end)
    wait_until(fn ->
      case GenServer.call({:global, StreamErrorConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    StreamErrorPublisher.publish_message("error_msg")

    # consume/1 is invoked exactly once — the ack prevents redelivery
    assert_receive :error_consume_called, 5_000
    refute_receive :error_consume_called, 500

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_error_receiver)
  end

  @tag :capture_log
  test "stream consumer does not create a dead-letter queue on :error return" do
    {:ok, cons_pid} = StreamErrorConsumer.start_link()
    {:ok, pub_pid} = StreamErrorPublisher.start_link()

    assert {:ok, _} = Mgmt.wait_for_queue(@error_q)
    wait_until(fn -> StreamErrorPublisher.publish_message("error_test") == :ok end)

    # Give time for message to be processed
    Process.sleep(500)

    refute Mgmt.queue_exists?("#{@error_q}.dead")

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "stream queue appears in management API with type 'stream'" do
    {:ok, cons_pid} = StreamNextConsumer.start_link()

    assert {:ok, info} = Mgmt.wait_for_queue(@next_q)
    assert info["type"] == "stream"
    assert info["durable"] == true

    GenServer.stop(cons_pid)
  end
end
