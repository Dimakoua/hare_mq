defmodule HareMq.Integration.RetryIntegrationTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.Test.RabbitMQManagement, as: Mgmt

  # ---- Test modules --------------------------------------------------------

  # Always returns :error. Large delay/retry values so messages sit in the
  # delay queue long enough to observe them.
  defmodule AlwaysErrorConsumer do
    use HareMq.Consumer,
      queue_name: "int_retry_delay_q",
      routing_key: "int_retry_delay_q",
      exchange: "int_retry_delay_exchange",
      delay_in_ms: 10_000,
      retry_limit: 10

    def consume(_), do: :error
  end

  # Always returns :error. Fast delay + low retry_limit so messages reach the
  # dead-letter queue quickly in tests.
  defmodule FastDeadLetterConsumer do
    use HareMq.Consumer,
      queue_name: "int_retry_dead_q",
      routing_key: "int_retry_dead_q",
      exchange: "int_retry_dead_exchange",
      delay_in_ms: 300,
      retry_limit: 1

    def consume(_), do: :error
  end

  defmodule DelayPublisher do
    use HareMq.Publisher,
      exchange: "int_retry_delay_exchange",
      routing_key: "int_retry_delay_q"
  end

  defmodule DeadPublisher do
    use HareMq.Publisher,
      exchange: "int_retry_dead_exchange",
      routing_key: "int_retry_dead_q"
  end

  # ---- Queue names ---------------------------------------------------------

  @delay_q "int_retry_delay_q"
  @dead_q "int_retry_dead_q"

  # ---- Setup / teardown ----------------------------------------------------

  setup do
    Application.put_env(:hare_mq, :amqp, url: Mgmt.amqp_url())
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_ms: 100})

    for name <- [AlwaysErrorConsumer, FastDeadLetterConsumer, DelayPublisher, DeadPublisher,
                 HareMq.Connection] do
      stop_global(name)
    end

    Process.sleep(150)

    for q <- [@delay_q, "#{@delay_q}.delay", "#{@delay_q}.dead",
              @dead_q, "#{@dead_q}.delay", "#{@dead_q}.dead"] do
      Mgmt.delete_queue(q)
    end

    stop_global(HareMq.Connection)
    {:ok, _} = Connection.start_link([])

    on_exit(fn ->
      for name <- [AlwaysErrorConsumer, FastDeadLetterConsumer, DelayPublisher, DeadPublisher,
                   HareMq.Connection] do
        stop_global(name)
      end

      Process.sleep(150)

      for q <- [@delay_q, "#{@delay_q}.delay", "#{@delay_q}.dead",
                @dead_q, "#{@dead_q}.delay", "#{@dead_q}.dead"] do
        Mgmt.delete_queue(q)
      end
    end)

    :ok
  end

  # ---- Tests ---------------------------------------------------------------

  @tag :capture_log
  test "failed message is routed to the delay queue" do
    {:ok, cons_pid} = AlwaysErrorConsumer.start_link()
    {:ok, pub_pid} = DelayPublisher.start_link()

    # Wait for both consumer and publisher to be fully connected and subscribed
    wait_until(fn ->
      case GenServer.call({:global, AlwaysErrorConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)
    wait_until(fn -> match?({:ok, _}, DelayPublisher.get_channel()) end)

    DelayPublisher.publish_message("to_delay")

    # After the consumer nacks the message, RetryPublisher sends it to
    # the delay queue. Verify via management API.
    assert :ok = Mgmt.wait_for_messages("#{@delay_q}.delay", 1, "/", 10_000)

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "message reaches the dead-letter queue after retry_limit exhaustion" do
    # retry_limit: 1, delay_in_ms: 300 ms
    # Flow:
    #   1st fail  → retry_count 0 < 1  → delay queue (300 ms TTL)
    #   after TTL → consumer gets msg  → retry_count 1 >= 1 → dead queue
    {:ok, cons_pid} = FastDeadLetterConsumer.start_link()
    {:ok, pub_pid} = DeadPublisher.start_link()

    wait_until(fn ->
      case GenServer.call({:global, FastDeadLetterConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)
    wait_until(fn -> match?({:ok, _}, DeadPublisher.get_channel()) end)

    DeadPublisher.publish_message("to_dead")

    assert :ok = Mgmt.wait_for_messages("#{@dead_q}.dead", 1, "/", 10_000)

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "each independently failing message adds to the dead-letter queue" do
    {:ok, cons_pid} = FastDeadLetterConsumer.start_link()
    {:ok, pub_pid} = DeadPublisher.start_link()

    wait_until(fn ->
      case GenServer.call({:global, FastDeadLetterConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)
    wait_until(fn -> match?({:ok, _}, DeadPublisher.get_channel()) end)

    DeadPublisher.publish_message("msg_a")
    DeadPublisher.publish_message("msg_b")

    assert :ok = Mgmt.wait_for_messages("#{@dead_q}.dead", 2, "/", 8_000)

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "delay queue is durable with x-message-ttl set to delay_in_ms" do
    {:ok, cons_pid} = AlwaysErrorConsumer.start_link()
    {:ok, pub_pid} = DelayPublisher.start_link()

    # Wait for consumer to declare topology before checking queue
    wait_until(fn ->
      case GenServer.call({:global, AlwaysErrorConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)

    assert {:ok, _} = Mgmt.wait_for_queue("#{@delay_q}.delay")

    {:ok, info} = Mgmt.get_queue("#{@delay_q}.delay")
    args = Map.new(info["arguments"])

    assert info["durable"] == true
    assert args["x-message-ttl"] == 10_000

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end

  @tag :capture_log
  test "dead-letter queue is durable" do
    {:ok, cons_pid} = FastDeadLetterConsumer.start_link()
    {:ok, pub_pid} = DeadPublisher.start_link()

    wait_until(fn ->
      case GenServer.call({:global, FastDeadLetterConsumer}, :get_channel) do
        %{consumer_tag: tag} when is_binary(tag) -> true
        _ -> false
      end
    end)
    wait_until(fn -> match?({:ok, _}, DeadPublisher.get_channel()) end)

    DeadPublisher.publish_message("trigger")
    assert :ok = Mgmt.wait_for_messages("#{@dead_q}.dead", 1, "/", 10_000)

    {:ok, info} = Mgmt.get_queue("#{@dead_q}.dead")
    assert info["durable"] == true

    GenServer.stop(pub_pid)
    GenServer.stop(cons_pid)
  end
end
