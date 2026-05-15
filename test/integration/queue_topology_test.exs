defmodule HareMq.Integration.QueueTopologyTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.Test.RabbitMQManagement, as: Mgmt

  # ---- Consumers and publishers used by topology tests ---------------------

  defmodule ClassicTopologyConsumer do
    use HareMq.Consumer,
      queue_name: "int_topology_classic",
      routing_key: "int_topology_classic",
      exchange: "int_topology_exchange",
      delay_in_ms: 10_000,
      retry_limit: 5

    def consume(_), do: :ok
  end

  defmodule StreamTopologyConsumer do
    use HareMq.Consumer,
      queue_name: "int_topology_stream",
      routing_key: "int_topology_stream",
      exchange: "int_topology_stream_exchange",
      stream: true

    def consume(_), do: :ok
  end

  defmodule TopologyPublisher do
    use HareMq.Publisher,
      exchange: "int_topology_publisher_exchange",
      routing_key: "int_topology_publisher_rk"
  end

  # ---- Queue / exchange names -----------------------------------------------

  @classic_q "int_topology_classic"
  @classic_delay_q "int_topology_classic.delay"
  @classic_dead_q "int_topology_classic.dead"
  @stream_q "int_topology_stream"
  @publisher_exchange "int_topology_publisher_exchange"

  # ---- Setup / teardown -----------------------------------------------------

  setup do
    Application.put_env(:hare_mq, :amqp, url: Mgmt.amqp_url())
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_ms: 100})

    # Stop anything left over from a previous test run
    for name <- [
          ClassicTopologyConsumer,
          StreamTopologyConsumer,
          TopologyPublisher,
          HareMq.Connection
        ] do
      stop_global(name)
    end

    Process.sleep(150)

    # Clean queues from previous runs
    for q <- [@classic_q, @classic_delay_q, @classic_dead_q, @stream_q] do
      Mgmt.delete_queue(q)
    end

    stop_global(HareMq.Connection)
    {:ok, _} = Connection.start_link([])

    on_exit(fn ->
      for name <- [
            ClassicTopologyConsumer,
            StreamTopologyConsumer,
            TopologyPublisher,
            HareMq.Connection
          ] do
        stop_global(name)
      end

      Process.sleep(150)

      for q <- [@classic_q, @classic_delay_q, @classic_dead_q, @stream_q] do
        Mgmt.delete_queue(q)
      end
    end)

    :ok
  end

  # ---- Classic consumer topology tests -------------------------------------

  describe "classic consumer topology" do
    @tag :capture_log
    test "declares a durable main queue" do
      {:ok, pid} = ClassicTopologyConsumer.start_link()
      assert {:ok, info} = Mgmt.wait_for_queue(@classic_q)
      assert info["durable"] == true
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "declares the delay queue" do
      {:ok, pid} = ClassicTopologyConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_q)
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_delay_q)
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "declares the dead-letter queue" do
      {:ok, pid} = ClassicTopologyConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_q)
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_dead_q)
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "delay queue has x-dead-letter-exchange argument" do
      {:ok, pid} = ClassicTopologyConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_delay_q)
      {:ok, info} = Mgmt.get_queue(@classic_delay_q)
      args = Map.new(info["arguments"])
      assert Map.has_key?(args, "x-dead-letter-exchange")
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "delay queue has x-message-ttl argument set to delay_in_ms" do
      {:ok, pid} = ClassicTopologyConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@classic_delay_q)
      {:ok, info} = Mgmt.get_queue(@classic_delay_q)
      args = Map.new(info["arguments"])
      assert args["x-message-ttl"] == 10_000
      GenServer.stop(pid)
    end
  end

  # ---- Stream consumer topology tests -------------------------------------

  describe "stream consumer topology" do
    @tag :capture_log
    test "declares only the main queue — no delay or dead-letter queues" do
      {:ok, pid} = StreamTopologyConsumer.start_link()
      assert {:ok, _} = Mgmt.wait_for_queue(@stream_q)
      refute Mgmt.queue_exists?("#{@stream_q}.delay")
      refute Mgmt.queue_exists?("#{@stream_q}.dead")
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "stream queue type is 'stream'" do
      {:ok, pid} = StreamTopologyConsumer.start_link()
      assert {:ok, info} = Mgmt.wait_for_queue(@stream_q)
      assert info["type"] == "stream"
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "stream queue is durable" do
      {:ok, pid} = StreamTopologyConsumer.start_link()
      assert {:ok, info} = Mgmt.wait_for_queue(@stream_q)
      assert info["durable"] == true
      GenServer.stop(pid)
    end
  end

  # ---- Publisher topology tests -------------------------------------------

  describe "publisher topology" do
    @tag :capture_log
    test "declares its exchange on connect" do
      {:ok, pid} = TopologyPublisher.start_link()
      wait_until(fn -> match?({:ok, _}, TopologyPublisher.get_channel()) end)
      assert Mgmt.exchange_exists?(@publisher_exchange)
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "exchange is durable" do
      {:ok, pid} = TopologyPublisher.start_link()
      wait_until(fn -> match?({:ok, _}, TopologyPublisher.get_channel()) end)
      {:ok, info} = Mgmt.get_exchange(@publisher_exchange)
      assert info["durable"] == true
      GenServer.stop(pid)
    end

    @tag :capture_log
    test "exchange type is topic" do
      {:ok, pid} = TopologyPublisher.start_link()
      wait_until(fn -> match?({:ok, _}, TopologyPublisher.get_channel()) end)
      {:ok, info} = Mgmt.get_exchange(@publisher_exchange)
      assert info["type"] == "topic"
      GenServer.stop(pid)
    end
  end
end
