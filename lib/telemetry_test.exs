defmodule HareMq.TelemetryTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.RetryPublisher
  alias HareMq.Configuration

  # ---------------------------------------------------------------------------
  # Shared test modules
  # ---------------------------------------------------------------------------

  defmodule TelPublisher do
    use HareMq.Publisher,
      exchange: "tel_test_exchange",
      routing_key: "tel_test_rk"
  end

  defmodule TelOkConsumer do
    use HareMq.Consumer,
      queue_name: "tel_ok_queue",
      routing_key: "tel_ok_rk",
      exchange: "tel_test_exchange",
      delay_in_ms: 10_000,
      retry_limit: 5

    def consume(_), do: :ok
  end

  defmodule TelErrorConsumer do
    use HareMq.Consumer,
      queue_name: "tel_error_queue",
      routing_key: "tel_error_rk",
      exchange: "tel_test_exchange",
      delay_in_ms: 10_000,
      retry_limit: 5

    def consume(_), do: :error
  end

  defmodule TelOkPublisher do
    use HareMq.Publisher,
      exchange: "tel_test_exchange",
      routing_key: "tel_ok_rk"
  end

  defmodule TelErrorPublisher do
    use HareMq.Publisher,
      exchange: "tel_test_exchange",
      routing_key: "tel_error_rk"
  end

  defmodule RetryTelPublisher do
    use HareMq.Publisher, exchange: "tel_test_exchange", routing_key: "tel_test_rk"
  end

  defmodule DeadTelPublisher do
    use HareMq.Publisher, exchange: "tel_test_exchange", routing_key: "tel_test_rk"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Attaches a telemetry handler that collects all matching events into an
  # Agent list. Returns {handler_id, agent_pid}. Call collect/1 to drain.
  defp attach_collector(events) do
    handler_id = make_ref()
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        Agent.update(agent, fn acc -> [{event, measurements, metadata} | acc] end)
      end,
      nil
    )

    {handler_id, agent}
  end

  defp collect(agent), do: Enum.reverse(Agent.get(agent, & &1))

  defp detach(handler_id), do: :telemetry.detach(handler_id)

  # Polls until at least one collected event matches the predicate or timeout.
  defp wait_for_event(agent, pred, timeout \\ 3_000) do
    deadline = :os.system_time(:millisecond) + timeout
    do_wait_event(agent, pred, deadline)
  end

  defp do_wait_event(agent, pred, deadline) do
    if Enum.any?(collect(agent), pred) do
      :ok
    else
      if :os.system_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(50)
        do_wait_event(agent, pred, deadline)
      end
    end
  end

  defp safe_stop(name) do
    case GenServer.whereis({:global, name}) do
      nil -> :ok
      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Setup / teardown
  # ---------------------------------------------------------------------------

  setup do
    Application.put_env(:hare_mq, :amqp, url: "amqp://guest:guest@rabbitmq")
    Application.put_env(:hare_mq, :configuration, %{reconnect_interval_in_ms: 100})

    for name <- [TelPublisher, TelOkPublisher, TelErrorPublisher, RetryTelPublisher,
                  DeadTelPublisher, TelOkConsumer, TelErrorConsumer, HareMq.Connection] do
      safe_stop(name)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Connection telemetry
  # ---------------------------------------------------------------------------

  describe "[:hare_mq, :connection, :connected]" do
    @tag :capture_log
    test "emitted when broker connection opens" do
      {id, agent} = attach_collector([[:hare_mq, :connection, :connected]])

      {:ok, pid} = Connection.start_link([])

      assert :ok =
               wait_for_event(agent, fn {event, _m, _meta} ->
                 event == [:hare_mq, :connection, :connected]
               end)

      events = collect(agent)
      {_, measurements, metadata} = Enum.find(events, fn {e, _, _} -> e == [:hare_mq, :connection, :connected] end)

      assert is_integer(measurements.system_time)
      assert metadata.connection_name == {:global, HareMq.Connection}
      assert is_binary(metadata.host)

      GenServer.stop(pid)
      detach(id)
    end

    @tag :capture_log
    test "emitted with custom connection name" do
      {id, agent} = attach_collector([[:hare_mq, :connection, :connected]])
      custom_name = {:global, :tel_test_conn}

      {:ok, pid} = Connection.start_link(name: custom_name)

      assert :ok =
               wait_for_event(agent, fn {_, _, meta} ->
                 meta[:connection_name] == custom_name
               end)

      GenServer.stop(pid)
      detach(id)
    end
  end

  describe "[:hare_mq, :connection, :reconnecting]" do
    @tag :capture_log
    test "emitted when amqp config is missing" do
      Application.delete_env(:hare_mq, :amqp)
      {id, agent} = attach_collector([[:hare_mq, :connection, :reconnecting]])

      {:ok, pid} = Connection.start_link([])

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :connection, :reconnecting]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :connection, :reconnecting] end)

      assert is_integer(measurements.retry_delay_ms)
      assert metadata.reason == :missing_config

      GenServer.stop(pid)
      detach(id)
    after
      Application.put_env(:hare_mq, :amqp, url: "amqp://guest:guest@rabbitmq")
    end
  end

  describe "[:hare_mq, :connection, :disconnected]" do
    @tag :capture_log
    test "emitted when the connection process goes down" do
      {:ok, conn_pid} = Connection.start_link([])
      assert wait_until(fn -> match?({:ok, _}, Connection.get_connection()) end)

      {id, agent} = attach_collector([[:hare_mq, :connection, :disconnected]])

      # Force-close the underlying AMQP connection so the monitor fires
      {:ok, %AMQP.Connection{pid: amqp_pid}} = Connection.get_connection()
      Process.exit(amqp_pid, :kill)

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :connection, :disconnected]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :connection, :disconnected] end)

      assert is_integer(measurements.system_time)
      assert metadata.connection_name == {:global, HareMq.Connection}
      assert metadata.reason != nil

      # conn_pid will have stopped itself; ensure cleanup
      if Process.alive?(conn_pid), do: GenServer.stop(conn_pid)
      detach(id)
    end
  end

  # ---------------------------------------------------------------------------
  # Publisher telemetry
  # ---------------------------------------------------------------------------

  describe "[:hare_mq, :publisher, :connected]" do
    @tag :capture_log
    test "emitted when publisher channel opens" do
      {:ok, _} = Connection.start_link([])
      {id, agent} = attach_collector([[:hare_mq, :publisher, :connected]])

      {:ok, pub_pid} = TelPublisher.start_link()

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :publisher, :connected]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :publisher, :connected] end)

      assert is_integer(measurements.system_time)
      assert metadata.publisher == TelPublisher
      assert metadata.exchange == "tel_test_exchange"
      assert metadata.routing_key == "tel_test_rk"

      GenServer.stop(pub_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end
  end

  describe "[:hare_mq, :publisher, :message, :published]" do
    @tag :capture_log
    test "emitted after successful publish of a binary message" do
      {:ok, _} = Connection.start_link([])
      {:ok, pub_pid} = TelPublisher.start_link()
      assert wait_until(fn -> match?({:ok, _}, TelPublisher.get_channel()) end)

      {id, agent} = attach_collector([[:hare_mq, :publisher, :message, :published]])

      assert :ok = TelPublisher.publish_message("hello")

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :publisher, :message, :published]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :publisher, :message, :published] end)

      assert is_integer(measurements.system_time)
      assert metadata.publisher == TelPublisher
      assert metadata.exchange == "tel_test_exchange"
      assert metadata.routing_key == "tel_test_rk"

      GenServer.stop(pub_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end

    @tag :capture_log
    test "emitted after successful publish of a map message" do
      {:ok, _} = Connection.start_link([])
      {:ok, pub_pid} = TelPublisher.start_link()
      assert wait_until(fn -> match?({:ok, _}, TelPublisher.get_channel()) end)

      {id, agent} = attach_collector([[:hare_mq, :publisher, :message, :published]])

      assert :ok = TelPublisher.publish_message(%{key: "value"})

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :publisher, :message, :published]
               end)

      GenServer.stop(pub_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end
  end

  describe "[:hare_mq, :publisher, :message, :not_connected]" do
    @tag :capture_log
    test "emitted when publish is attempted without a channel" do
      # Do NOT start a connection — publisher will have no channel
      {:ok, pub_pid} = TelPublisher.start_link()

      {id, agent} = attach_collector([[:hare_mq, :publisher, :message, :not_connected]])

      assert {:error, :not_connected} = TelPublisher.publish_message("orphan")

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :publisher, :message, :not_connected]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :publisher, :message, :not_connected] end)

      assert is_integer(measurements.system_time)
      assert metadata.publisher == TelPublisher

      GenServer.stop(pub_pid)
      detach(id)
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer telemetry
  # ---------------------------------------------------------------------------

  describe "[:hare_mq, :consumer, :connected]" do
    @tag :capture_log
    test "emitted when consumer channel and Basic.consume succeed" do
      {:ok, _} = Connection.start_link([])
      {id, agent} = attach_collector([[:hare_mq, :consumer, :connected]])

      {:ok, cons_pid} = TelOkConsumer.start_link()

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :consumer, :connected]
               end)

      {_, measurements, metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :consumer, :connected] end)

      assert is_integer(measurements.system_time)
      assert metadata.consumer == TelOkConsumer
      assert metadata.queue == "tel_ok_queue"
      assert metadata.exchange == "tel_test_exchange"
      assert metadata.routing_key == "tel_ok_rk"
      assert metadata.stream == false

      GenServer.stop(cons_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end
  end

  describe "[:hare_mq, :consumer, :message, :start/:stop]" do
    @tag :capture_log
    test "start and stop events emitted when consume/1 returns :ok" do
      {:ok, _} = Connection.start_link([])
      {:ok, pub_pid} = TelOkPublisher.start_link()
      {:ok, cons_pid} = TelOkConsumer.start_link()

      assert wait_until(fn -> match?({:ok, _}, TelOkPublisher.get_channel()) end)

      assert wait_until(fn ->
        case GenServer.call({:global, TelOkConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      {id, agent} =
        attach_collector([
          [:hare_mq, :consumer, :message, :start],
          [:hare_mq, :consumer, :message, :stop]
        ])

      TelOkPublisher.publish_message("telemetry span test")

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :consumer, :message, :stop]
               end)

      events = collect(agent)

      start_event = Enum.find(events, fn {e, _, _} -> e == [:hare_mq, :consumer, :message, :start] end)
      stop_event  = Enum.find(events, fn {e, _, _} -> e == [:hare_mq, :consumer, :message, :stop] end)

      assert start_event != nil
      assert stop_event  != nil

      {_, stop_measurements, stop_metadata} = stop_event
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.result == :ok
      assert stop_metadata.queue == "tel_ok_queue"
      assert stop_metadata.exchange == "tel_test_exchange"

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end

    @tag :capture_log
    test "stop event has result :error when consume/1 returns :error" do
      {:ok, _} = Connection.start_link([])

      {:ok, pub_pid} = TelErrorPublisher.start_link()
      {:ok, cons_pid} = TelErrorConsumer.start_link()

      assert wait_until(fn -> match?({:ok, _}, TelErrorPublisher.get_channel()) end)

      assert wait_until(fn ->
        case GenServer.call({:global, TelErrorConsumer}, :get_channel) do
          %{consumer_tag: tag} when is_binary(tag) -> true
          _ -> false
        end
      end)

      {id, agent} = attach_collector([[:hare_mq, :consumer, :message, :stop]])

      TelErrorPublisher.publish_message("error message")

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :consumer, :message, :stop]
               end)

      {_, _, stop_metadata} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :consumer, :message, :stop] end)

      assert stop_metadata.result == :error

      GenServer.stop(pub_pid)
      GenServer.stop(cons_pid)
      stop_global(HareMq.Connection)
      detach(id)
    end
  end

  # ---------------------------------------------------------------------------
  # Retry publisher telemetry
  # ---------------------------------------------------------------------------

  describe "[:hare_mq, :retry_publisher, :message, :retried]" do
    setup do
      {:ok, _} = Connection.start_link([])
      {:ok, _pub_pid} = RetryTelPublisher.start_link()
      assert wait_until(fn -> match?({:ok, _}, RetryTelPublisher.get_channel()) end)
      {:ok, channel} = RetryTelPublisher.get_channel()

      config = %Configuration{
        channel: channel,
        queue_name: "tel_retry_q",
        delay_queue_name: "tel_retry_q.delay",
        dead_queue_name: "tel_retry_q.dead",
        retry_limit: 5,
        delay_cascade_in_ms: []
      }

      on_exit(fn ->
        safe_stop(RetryTelPublisher)
        safe_stop(HareMq.Connection)
      end)

      {:ok, config: config}
    end

    test "emitted when message is sent to standard delay queue", %{config: config} do
      {id, agent} = attach_collector([[:hare_mq, :retry_publisher, :message, :retried]])

      metadata = %{headers: [{"retry_count", :long, 1}]}
      RetryPublisher.republish("payload", config, metadata)

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :retry_publisher, :message, :retried]
               end)

      {_, measurements, meta} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :retry_publisher, :message, :retried] end)

      assert measurements.retry_count == 2
      assert is_integer(measurements.system_time)
      assert meta.queue == "tel_retry_q"
      assert meta.delay_queue == "tel_retry_q.delay"

      detach(id)
    end

    test "emitted with correct delay queue name for cascade", %{config: config} do
      cascade_config = %{config | delay_cascade_in_ms: [1_000, 5_000, 10_000]}

      {id, agent} = attach_collector([[:hare_mq, :retry_publisher, :message, :retried]])

      metadata = %{headers: [{"retry_count", :long, 0}]}
      RetryPublisher.republish("payload", cascade_config, metadata)

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :retry_publisher, :message, :retried]
               end)

      {_, _, meta} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :retry_publisher, :message, :retried] end)

      assert meta.delay_queue == "tel_retry_q.delay.1000"

      detach(id)
    end
  end

  describe "[:hare_mq, :retry_publisher, :message, :dead_lettered]" do
    setup do
      {:ok, _} = Connection.start_link([])
      {:ok, _pub_pid} = DeadTelPublisher.start_link()
      assert wait_until(fn -> match?({:ok, _}, DeadTelPublisher.get_channel()) end)
      {:ok, channel} = DeadTelPublisher.get_channel()

      config = %Configuration{
        channel: channel,
        queue_name: "tel_dead_q",
        delay_queue_name: "tel_dead_q.delay",
        dead_queue_name: "tel_dead_q.dead",
        retry_limit: 1,
        delay_cascade_in_ms: []
      }

      on_exit(fn ->
        safe_stop(DeadTelPublisher)
        safe_stop(HareMq.Connection)
      end)

      {:ok, config: config}
    end

    test "emitted when retry_count equals retry_limit", %{config: config} do
      {id, agent} = attach_collector([[:hare_mq, :retry_publisher, :message, :dead_lettered]])

      # retry_count 1 == retry_limit 1 → dead-letter path
      metadata = %{headers: [{"retry_count", :long, 1}]}
      RetryPublisher.republish("payload", config, metadata)

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :retry_publisher, :message, :dead_lettered]
               end)

      {_, measurements, meta} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :retry_publisher, :message, :dead_lettered] end)

      assert measurements.retry_count == 1
      assert is_integer(measurements.system_time)
      assert meta.queue == "tel_dead_q"
      assert meta.dead_queue == "tel_dead_q.dead"

      detach(id)
    end

    test "emitted when retry_count exceeds retry_limit", %{config: config} do
      {id, agent} = attach_collector([[:hare_mq, :retry_publisher, :message, :dead_lettered]])

      metadata = %{headers: [{"retry_count", :long, 5}]}
      RetryPublisher.republish("payload", config, metadata)

      assert :ok =
               wait_for_event(agent, fn {event, _, _} ->
                 event == [:hare_mq, :retry_publisher, :message, :dead_lettered]
               end)

      {_, measurements, _} =
        Enum.find(collect(agent), fn {e, _, _} -> e == [:hare_mq, :retry_publisher, :message, :dead_lettered] end)

      assert measurements.retry_count == 5

      detach(id)
    end
  end
end
