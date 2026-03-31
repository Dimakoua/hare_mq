defmodule HareMq.Consumer.BatchTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.Test.RabbitMQManagement, as: Mgmt

  defmodule BatchTestPublisher do
    use HareMq.Publisher,
      exchange: "batch_test_exchange",
      routing_key: "batch_test_queue"
  end

  defmodule BatchTestConsumer do
    use HareMq.Consumer,
      queue_name: "batch_test_queue",
      routing_key: "batch_test_queue",
      exchange: "batch_test_exchange",
      batch_size: 3

    def consume(messages, :batch) do
      case :global.whereis_name(:batch_test_pid) do
        pid when is_pid(pid) -> send(pid, {:batched, messages})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule BatchTimeoutConsumer do
    use HareMq.Consumer,
      queue_name: "batch_timeout_queue",
      routing_key: "batch_timeout_queue",
      exchange: "batch_timeout_exchange",
      batch_size: 5,
      batch_timeout_ms: 1000

    def consume(messages, :batch) do
      case :global.whereis_name(:batch_timeout_test_pid) do
        pid when is_pid(pid) -> send(pid, {:batched, messages})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule BatchTimeoutPublisher do
    use HareMq.Publisher,
      exchange: "batch_timeout_exchange",
      routing_key: "batch_timeout_queue"
  end

  defmodule StreamBatchConsumer do
    use HareMq.Consumer,
      queue_name: "stream_batch_queue",
      routing_key: "stream_batch_queue",
      exchange: "stream_batch_exchange",
      stream: true,
      batch_size: 3

    def consume(messages, :batch) do
      case :global.whereis_name(:stream_batch_test_pid) do
        pid when is_pid(pid) -> send(pid, {:batched, messages})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule StreamBatchPublisher do
    use HareMq.Publisher,
      exchange: "stream_batch_exchange",
      routing_key: "stream_batch_queue"
  end

  defmodule BatchRetryConsumer do
    use HareMq.Consumer,
      queue_name: "batch_retry_queue",
      routing_key: "batch_retry_queue",
      exchange: "batch_retry_exchange",
      batch_size: 2,
      retry_limit: 1,
      delay_in_ms: 100

    def consume(messages, :batch) do
      case :global.whereis_name(:batch_retry_test_pid) do
        pid when is_pid(pid) -> send(pid, {:batched, messages})
        _ -> :ok
      end

      # First attempt fails, triggering republish
      :error
    end
  end

  defmodule BatchRetryPublisher do
    use HareMq.Publisher,
      exchange: "batch_retry_exchange",
      routing_key: "batch_retry_queue"
  end

  setup do
    Application.put_env(:hare_mq, :amqp, url: Mgmt.amqp_url())
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_ms: 100})
    stop_global(HareMq.Connection)
    {:ok, _pid} = Connection.start_link([])

    on_exit(fn ->
      stop_global(HareMq.Connection)
      # Clean up test queues
      for queue <- [
            "batch_test_queue",
            "batch_test_queue.delay",
            "batch_test_queue.dead",
            "batch_timeout_queue",
            "batch_timeout_queue.delay",
            "batch_timeout_queue.dead",
            "stream_batch_queue",
            "batch_retry_queue",
            "batch_retry_queue.delay",
            "batch_retry_queue.dead"
          ] do
        Mgmt.delete_queue(queue)
      end
    end)

    :ok
  end

  @tag :capture_log
  test "consumes messages in batches" do
    :global.register_name(:batch_test_pid, self())

    {:ok, pub_pid} = BatchTestPublisher.start_link()
    {:ok, cons_pid} = BatchTestConsumer.start_link()

    wait_until(fn ->
      case GenServer.call({:global, BatchTestConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    # Publish first two messages
    wait_until(fn -> BatchTestPublisher.publish_message("msg1") == :ok end)
    wait_until(fn -> BatchTestPublisher.publish_message("msg2") == :ok end)

    # Should NOT have received batch yet
    refute_receive {:batched, _}, 500

    # Publish third message
    wait_until(fn -> BatchTestPublisher.publish_message("msg3") == :ok end)

    # Should have received batch now
    assert_receive {:batched, ["msg1", "msg2", "msg3"]}, 2000

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:batch_test_pid)
  end

  @tag :capture_log
  test "flushes partial batch on timeout" do
    :global.register_name(:batch_timeout_test_pid, self())

    {:ok, pub_pid} = BatchTimeoutPublisher.start_link()
    {:ok, cons_pid} = BatchTimeoutConsumer.start_link()

    wait_until(fn ->
      case GenServer.call({:global, BatchTimeoutConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    # Publish only 2 messages (batch_size is 5)
    wait_until(fn -> BatchTimeoutPublisher.publish_message("msg1") == :ok end)
    wait_until(fn -> BatchTimeoutPublisher.publish_message("msg2") == :ok end)

    # Should NOT have received batch yet (not full)
    refute_receive {:batched, _}, 500

    # Wait for timeout (1000ms) and a bit more for processing
    assert_receive {:batched, ["msg1", "msg2"]}, 2000

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:batch_timeout_test_pid)
  end

  @tag :capture_log
  test "stream queue batch processing" do
    :global.register_name(:stream_batch_test_pid, self())

    {:ok, pub_pid} = StreamBatchPublisher.start_link()
    {:ok, cons_pid} = StreamBatchConsumer.start_link()

    wait_until(fn ->
      case GenServer.call({:global, StreamBatchConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    # Publish batch for stream consumer
    wait_until(fn -> StreamBatchPublisher.publish_message("stream_msg1") == :ok end)
    wait_until(fn -> StreamBatchPublisher.publish_message("stream_msg2") == :ok end)
    wait_until(fn -> StreamBatchPublisher.publish_message("stream_msg3") == :ok end)

    # Should receive batch (stream queues auto-ack)
    assert_receive {:batched, ["stream_msg1", "stream_msg2", "stream_msg3"]}, 2000

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:stream_batch_test_pid)
  end

  @tag :capture_log
  test "batch republish on consumer error" do
    :global.register_name(:batch_retry_test_pid, self())

    {:ok, pub_pid} = BatchRetryPublisher.start_link()
    {:ok, cons_pid} = BatchRetryConsumer.start_link()

    wait_until(fn ->
      case GenServer.call({:global, BatchRetryConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    # Publish batch of 2 messages
    wait_until(fn -> BatchRetryPublisher.publish_message("retry_msg1") == :ok end)
    wait_until(fn -> BatchRetryPublisher.publish_message("retry_msg2") == :ok end)

    # Should receive batch (messages sent to consumer)
    assert_receive {:batched, ["retry_msg1", "retry_msg2"]}, 2000

    # Wait for async republish task to complete - messages should appear in delay queue
    delay_queue = "batch_retry_queue.delay"
    assert :ok = Mgmt.wait_for_messages(delay_queue, 2, "/", 5000)

    # Messages should be republished to delay queue due to :error return
    # Verify messages appear in delay queue (batch_retry_queue.delay - single delay value)

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:batch_retry_test_pid)
  end

  @tag :capture_log
  test "batch messages successfully republish to delay queue" do
    :global.register_name(:batch_retry_test_pid, self())

    {:ok, pub_pid} = BatchRetryPublisher.start_link()
    {:ok, cons_pid} = BatchRetryConsumer.start_link()

    wait_until(fn ->
      case GenServer.call({:global, BatchRetryConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    # Publish batch
    wait_until(fn -> BatchRetryPublisher.publish_message("delay_msg1") == :ok end)
    wait_until(fn -> BatchRetryPublisher.publish_message("delay_msg2") == :ok end)

    # Verify batch was processed by consumer
    assert_receive {:batched, ["delay_msg1", "delay_msg2"]}, 2000

    # Wait for async republish task to complete - messages should appear in delay queue
    delay_queue = "batch_retry_queue.delay"
    assert :ok = Mgmt.wait_for_messages(delay_queue, 2, "/", 5000)

    # Check delay queue has messages (consumer returns :error)
    # Single delay value creates {queue_name}.delay queue
    assert {:ok, _} = Mgmt.wait_for_queue(delay_queue, "/", 3000)
    assert :ok = Mgmt.wait_for_messages(delay_queue, 2, "/", 3000)

    # Verify queue state
    {:ok, delay_info} = Mgmt.get_queue(delay_queue)

    assert delay_info["messages"] >= 2,
           "Expected at least 2 messages in delay queue, got #{delay_info["messages"]}"

    assert :ok = GenServer.stop(pub_pid)
    assert :ok = GenServer.stop(cons_pid)
  after
    :global.unregister_name(:batch_retry_test_pid)
  end
end
