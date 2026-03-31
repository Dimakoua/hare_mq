defmodule HareMq.Integration.ExtendedTopologyTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.Test.RabbitMQManagement, as: Mgmt

  # ---- Test consumers and publishers ---------------------------------------

  # Happy-path consumer: acks every message and notifies the test process.
  defmodule EchoConsumer do
    use HareMq.Consumer,
      queue_name: "int_ext_echo_q",
      routing_key: "int_ext_echo_q",
      exchange: "int_ext_echo_exchange",
      delay_in_ms: 10_000,
      retry_limit: 5

    def consume(message) do
      case :global.whereis_name(:ext_echo_receiver) do
        pid when is_pid(pid) -> send(pid, {:received, message})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule EchoPublisher do
    use HareMq.Publisher,
      exchange: "int_ext_echo_exchange",
      routing_key: "int_ext_echo_q"
  end

  # Cascade-delay consumer: always errors so we can observe routing.
  defmodule CascadeConsumer do
    use HareMq.Consumer,
      queue_name: "int_cascade_q",
      routing_key: "int_cascade_q",
      exchange: "int_cascade_exchange",
      delay_cascade_in_ms: [5_000, 15_000, 30_000],
      retry_limit: 10

    def consume(_), do: :error
  end

  defmodule CascadePublisher do
    use HareMq.Publisher,
      exchange: "int_cascade_exchange",
      routing_key: "int_cascade_q"
  end

  # Used to verify dead-queue TTL argument.
  defmodule DeadTTLConsumer do
    use HareMq.Consumer,
      queue_name: "int_dead_ttl_q",
      routing_key: "int_dead_ttl_q",
      exchange: "int_dead_ttl_exchange",
      delay_in_ms: 300,
      retry_limit: 1

    def consume(_), do: :error
  end

  defmodule DeadTTLPublisher do
    use HareMq.Publisher,
      exchange: "int_dead_ttl_exchange",
      routing_key: "int_dead_ttl_q"
  end

  # ---- Queue / exchange names -----------------------------------------------

  @echo_q "int_ext_echo_q"
  @echo_exchange "int_ext_echo_exchange"
  @cascade_q "int_cascade_q"
  @dead_ttl_q "int_dead_ttl_q"

  # ---- Setup / teardown -----------------------------------------------------

  setup do
    Application.put_env(:hare_mq, :amqp, url: Mgmt.amqp_url())
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_ms: 100})

    for name <- [
          EchoConsumer,
          EchoPublisher,
          CascadeConsumer,
          CascadePublisher,
          DeadTTLConsumer,
          DeadTTLPublisher,
          HareMq.Connection
        ] do
      stop_global(name)
    end

    Process.sleep(150)

    for q <- [
          @echo_q,
          "#{@echo_q}.delay",
          "#{@echo_q}.dead",
          @cascade_q,
          "#{@cascade_q}.dead",
          "#{@cascade_q}.delay.5000",
          "#{@cascade_q}.delay.15000",
          "#{@cascade_q}.delay.30000",
          @dead_ttl_q,
          "#{@dead_ttl_q}.delay",
          "#{@dead_ttl_q}.dead"
        ] do
      Mgmt.delete_queue(q)
    end

    stop_global(HareMq.Connection)
    {:ok, _} = Connection.start_link([])

    on_exit(fn ->
      for name <- [
            EchoConsumer,
            EchoPublisher,
            CascadeConsumer,
            CascadePublisher,
            DeadTTLConsumer,
            DeadTTLPublisher,
            HareMq.Connection
          ] do
        stop_global(name)
      end

      Process.sleep(150)

      for q <- [
            @echo_q,
            "#{@echo_q}.delay",
            "#{@echo_q}.dead",
            @cascade_q,
            "#{@cascade_q}.dead",
            "#{@cascade_q}.delay.5000",
            "#{@cascade_q}.delay.15000",
            "#{@cascade_q}.delay.30000",
            @dead_ttl_q,
            "#{@dead_ttl_q}.delay",
            "#{@dead_ttl_q}.dead"
          ] do
        Mgmt.delete_queue(q)
      end
    end)

    :ok
  end

  # ---- End-to-end happy path -----------------------------------------------

  describe "end-to-end happy path (classic consumer)" do
    @tag :capture_log
    test "published message is delivered to and acked by the consumer" do
      :global.register_name(:ext_echo_receiver, self())

      {:ok, cons_pid} = EchoConsumer.start_link()
      {:ok, pub_pid} = EchoPublisher.start_link()

      wait_until(fn -> match?({:ok, _}, EchoPublisher.get_channel()) end)

      wait_until(fn ->
        case GenServer.call({:global, EchoConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      EchoPublisher.publish_message("hello integration")

      assert_receive {:received, "hello integration"}, 5_000

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
    after
      :global.unregister_name(:ext_echo_receiver)
    end

    @tag :capture_log
    test "successfully consumed message does not remain in the queue" do
      :global.register_name(:ext_echo_receiver, self())

      {:ok, cons_pid} = EchoConsumer.start_link()
      {:ok, pub_pid} = EchoPublisher.start_link()

      wait_until(fn -> match?({:ok, _}, EchoPublisher.get_channel()) end)

      wait_until(fn ->
        case GenServer.call({:global, EchoConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      EchoPublisher.publish_message("gone after ack")
      assert_receive {:received, "gone after ack"}, 5_000

      # Brief settling time for the ack to be processed by the broker
      Process.sleep(300)

      {:ok, info} = Mgmt.get_queue(@echo_q)
      assert Map.get(info, "messages", 0) == 0

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
    after
      :global.unregister_name(:ext_echo_receiver)
    end
  end

  # ---- Consumer exchange declaration ---------------------------------------

  describe "consumer exchange declaration" do
    @tag :capture_log
    test "consumer declares its routing exchange as topic" do
      {:ok, pid} = EchoConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@echo_q)
      {:ok, info} = Mgmt.get_exchange(@echo_exchange)
      assert info["type"] == "topic"
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "consumer declares the dead-letter (queue-name) exchange as topic" do
      {:ok, pid} = EchoConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@echo_q)
      # The consumer declares a second exchange named after the queue itself;
      # the delay queue routes expired messages back through it.
      {:ok, info} = Mgmt.get_exchange(@echo_q)
      assert info["type"] == "topic"
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "both consumer exchanges are durable" do
      {:ok, pid} = EchoConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@echo_q)
      {:ok, routing_info} = Mgmt.get_exchange(@echo_exchange)
      {:ok, dl_info} = Mgmt.get_exchange(@echo_q)
      assert routing_info["durable"] == true
      assert dl_info["durable"] == true
      GenServer.stop(pid)
    end
  end

  # ---- Delay queue arguments -----------------------------------------------

  describe "delay queue arguments" do
    @tag :capture_log
    test "delay queue has x-dead-letter-routing-key set to the routing key" do
      {:ok, pid} = EchoConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue("#{@echo_q}.delay")
      {:ok, info} = Mgmt.get_queue("#{@echo_q}.delay")
      args = Map.new(info["arguments"])
      assert args["x-dead-letter-routing-key"] == @echo_q
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "delay queue x-dead-letter-exchange routes back through the queue-name exchange" do
      {:ok, pid} = EchoConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue("#{@echo_q}.delay")
      {:ok, info} = Mgmt.get_queue("#{@echo_q}.delay")
      args = Map.new(info["arguments"])
      # Expired messages in the delay queue are re-routed via the exchange
      # named after the queue (the dead-letter exchange), which is bound to
      # the main queue with the correct routing key.
      assert args["x-dead-letter-exchange"] == @echo_q
      GenServer.stop(pid)
    end
  end

  # ---- Dead-letter queue arguments -----------------------------------------

  describe "dead-letter queue arguments" do
    @tag :capture_log
    test "dead queue has x-message-ttl argument set" do
      {:ok, cons_pid} = DeadTTLConsumer.start_link()
      {:ok, pub_pid} = DeadTTLPublisher.start_link()

      wait_until(fn ->
        case GenServer.call({:global, DeadTTLConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      wait_until(fn -> match?({:ok, _}, DeadTTLPublisher.get_channel()) end)

      DeadTTLPublisher.publish_message("trigger")
      assert :ok = Mgmt.wait_for_messages("#{@dead_ttl_q}.dead", 1, "/", 8_000)

      {:ok, info} = Mgmt.get_queue("#{@dead_ttl_q}.dead")
      args = Map.new(info["arguments"])
      assert Map.has_key?(args, "x-message-ttl")
      assert args["x-message-ttl"] > 0

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
    end
  end

  # ---- delay_cascade_in_ms topology ----------------------------------------

  describe "delay_cascade_in_ms topology" do
    @tag :capture_log
    test "creates one delay queue per cascade step" do
      {:ok, pid} = CascadeConsumer.start_link()

      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.5000")
      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.15000")
      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.30000")

      # No generic .delay queue should exist when using cascade mode
      refute Mgmt.queue_exists?("#{@cascade_q}.delay")

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "each cascade delay queue has the correct x-message-ttl" do
      {:ok, pid} = CascadeConsumer.start_link()

      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.5000")

      for {queue_suffix, expected_ttl} <- [{"5000", 5_000}, {"15000", 15_000}, {"30000", 30_000}] do
        {:ok, info} = Mgmt.get_queue("#{@cascade_q}.delay.#{queue_suffix}")
        args = Map.new(info["arguments"])

        assert args["x-message-ttl"] == expected_ttl,
               "expected x-message-ttl #{expected_ttl} for #{@cascade_q}.delay.#{queue_suffix}, got #{inspect(args)}"
      end

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "all cascade delay queues are durable" do
      {:ok, pid} = CascadeConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.5000")

      for suffix <- ["5000", "15000", "30000"] do
        {:ok, info} = Mgmt.get_queue("#{@cascade_q}.delay.#{suffix}")
        assert info["durable"] == true, "#{@cascade_q}.delay.#{suffix} should be durable"
      end

      GenServer.stop(pid)
    end

    @tag :capture_log
    test "each cascade delay queue has x-dead-letter-exchange pointing back to the queue exchange" do
      {:ok, pid} = CascadeConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue("#{@cascade_q}.delay.5000")

      for suffix <- ["5000", "15000", "30000"] do
        {:ok, info} = Mgmt.get_queue("#{@cascade_q}.delay.#{suffix}")
        args = Map.new(info["arguments"])

        assert args["x-dead-letter-exchange"] == @cascade_q,
               "#{@cascade_q}.delay.#{suffix} should have x-dead-letter-exchange = #{@cascade_q}"
      end

      GenServer.stop(pid)
    end
  end

  # ---- delay_cascade_in_ms routing -----------------------------------------

  describe "delay_cascade_in_ms routing" do
    @tag :capture_log
    test "first failure routes to the smallest delay queue" do
      {:ok, cons_pid} = CascadeConsumer.start_link()
      {:ok, pub_pid} = CascadePublisher.start_link()

      wait_until(fn ->
        case GenServer.call({:global, CascadeConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      wait_until(fn -> match?({:ok, _}, CascadePublisher.get_channel()) end)

      # Verify the cascade delay queue is in place before publishing
      assert Mgmt.queue_exists?("#{@cascade_q}.delay.5000"),
             "cascade delay queue should exist before publishing"

      assert :ok = CascadePublisher.publish_message("should_retry")

      # The consumer always returns :error, so the first nack (retry_count 0)
      # should land in the 5_000 ms delay queue (Enum.at(sorted, 0)).
      assert :ok = Mgmt.wait_for_messages("#{@cascade_q}.delay.5000", 1, "/", 8_000)

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
    end
  end
end
