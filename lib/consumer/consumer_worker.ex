defmodule HareMq.Worker.Consumer do
  use GenServer
  require Logger
  use AMQP

  @moduledoc """
  Internal GenServer that manages a single AMQP channel and processes messages.

  Not intended to be used directly — instantiated by `HareMq.Consumer` and
  `HareMq.DynamicConsumer` macros.

  ## Lifecycle

  1. On `init/1` sends itself `{:connect, opts}`.
  2. Opens a channel on the active `HareMq.Connection`.
  3. Calls `declare_queues/1` — for stream queues only `x-queue-type: stream` is
     declared; standard queues get the full exchange + delay + dead-letter topology.
  4. Calls `Basic.consume/3` — stream consumers pass `x-stream-offset` in the
     arguments; standard consumers use no extra arguments.
  5. On graceful cancel or channel/connection drop the GenServer stops and is
     restarted by its supervisor.

  ## Stream behaviour

  When `config[:stream]` is `true`:
  - Only the main queue is declared (`x-queue-type: stream`).
  - `Basic.consume/3` includes the `x-stream-offset` argument derived from
    `config[:stream_offset]` (string, integer, or `%DateTime{}`).
  - `process_result/5` always acks regardless of the `consume_fn` return value —
    stream logs are immutable so nack/retry is meaningless.
  """

  defp reconnect_interval,
    do:
      (Application.get_env(:hare_mq, :configuration) || [])[:reconnect_interval_in_ms] || 10_000

  def start_link([config: config, consume: _] = opts) do
    HareMq.GlobalNodeManager.wait_for_all_nodes_ready(config[:consumer_name])

    GenServer.start_link(__MODULE__, opts, name: {:global, config[:consumer_name]})
    |> HareMq.CodeFlow.successful_start()
  end

  # start from Dynamic Supervisor
  def start_link({name, opts}) do
    GenServer.start_link(__MODULE__, opts, name: {:global, name})
    |> HareMq.CodeFlow.successful_start()
  end

  def init([config: _, consume: _] = opts) do
    Process.flag(:trap_exit, true)

    send(self(), {:connect, opts})
    {:ok, %HareMq.Configuration{}}
  end

  def declare_queues(%HareMq.Configuration{stream: true} = config) do
    if config.exchange do
      :ok = HareMq.Exchange.declare(channel: config.channel, name: config.exchange, type: :topic)
      {:ok, _} = HareMq.Queue.declare_stream_queue(config)
      :ok = HareMq.Queue.bind(config)
    else
      {:ok, _} = HareMq.Queue.declare_stream_queue(config)
    end

    :ok
  end

  def declare_queues(config) do
    :ok = HareMq.Exchange.declare(channel: config.channel, name: config.exchange, type: :topic)
    :ok = HareMq.Exchange.declare(channel: config.channel, name: config.queue_name, type: :topic)
    {:ok, _} = HareMq.Queue.declare_queue(config)
    {:ok, _} = HareMq.Queue.declare_delay_queue(config)
    {:ok, _} = HareMq.Queue.declare_dead_queue(config)
    :ok = HareMq.Exchange.bind(config)
    :ok = HareMq.Queue.bind(config)
  end

  def get_channel(consumer_name) do
    case GenServer.call(consumer_name, :get_channel) do
      nil -> {:error, :not_connected}
      state -> {:ok, state}
    end
  end

  defp process_result(_result, _payload, %{stream: true} = state, tag, _metadata) do
    # Stream queues are immutable — ack to advance the credit window, never retry
    Basic.ack(state.channel, tag)
  end

  defp process_result(result, payload, state, tag, metadata) do
    case result do
      :ok -> Basic.ack(state.channel, tag)
      {:ok, _} -> Basic.ack(state.channel, tag)
      :error -> retry(payload, state, tag, metadata)
      {:error, _} -> retry(payload, state, tag, metadata)
    end
  end

  defp retry(payload, state, tag, metadata) do
    Basic.nack(state.channel, tag, multiple: false, requeue: false)

    Task.start(fn -> HareMq.RetryPublisher.republish(payload, state, metadata) end)
  end

  def republish_dead_messages(consumer_name, count \\ 1) when is_number(count) do
    case get_channel(consumer_name) do
      {:error, :not_connected} ->
        {:error, :not_connected}

      {:ok, configures} ->
        HareMq.RetryPublisher.republish_dead_messages(configures, count)
    end
  end

  def handle_call(:get_channel, _, state) do
    {:reply, state, state}
  end

  def handle_call(:get_config, _, state) do
    {:reply, state, state}
  end

  def handle_call(:cancel_consume, _, state) do
    Basic.cancel(state.channel, state.consumer_tag)
    {:reply, :ok, HareMq.Configuration.cancel_consume(state)}
  end

  def handle_info({:connect, [config: config, consume: consume] = opts}, state) do
    case HareMq.Connection.get_connection(config[:connection_name] || {:global, HareMq.Connection}) do
      {:ok, conn} ->
        # Get notifications when the connection goes down
        Process.monitor(conn.pid)

        case Channel.open(conn) do
          {:ok, chan} ->
            Process.monitor(chan.pid)

            queue_configuration =
              HareMq.Configuration.get_queue_configuration(
                channel: chan,
                consume_fn: consume,
                name: config[:queue_name],
                exchange: config[:exchange],
                routing_key: config[:routing_key],
                delay_in_ms: config[:delay_in_ms],
                retry_limit: config[:retry_limit],
                delay_cascade_in_ms: config[:delay_cascade_in_ms],
                stream: config[:stream],
                stream_offset: config[:stream_offset]
              )

            Basic.qos(chan, prefetch_count: config[:prefetch_count])

            declare_queues(queue_configuration)

            {:ok, consumer_tag} = Basic.consume(chan, config[:queue_name], nil, stream_consume_opts(queue_configuration))

            :telemetry.execute(
              [:hare_mq, :consumer, :connected],
              %{system_time: System.system_time()},
              %{
                consumer: config[:consumer_name],
                queue: config[:queue_name],
                exchange: config[:exchange],
                routing_key: config[:routing_key],
                stream: config[:stream] || false
              }
            )

            {:noreply, HareMq.Configuration.set_consumer_tag(queue_configuration, consumer_tag)}

          _ ->
            Logger.error("[consumer_worker] Faile to open channel!")
            Process.send_after(self(), {:connect, opts}, reconnect_interval())
            {:noreply, state}
        end

      {:error, _} ->
        Logger.error("[consumer_worker] Failed to connect. Reconnecting later...")
        # Retry later
        Process.send_after(self(), {:connect, opts}, reconnect_interval())
        {:noreply, state}
    end
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.info(
      "Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)"
    )

    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:basic_deliver, _payload, %{delivery_tag: tag, redelivered: _redelivered} = _metadata},
        %{state: :canceled} = state
      ) do
    Basic.nack(state.channel, tag, multiple: false, requeue: true)
    {:noreply, state}
  end

  def handle_info(
        {:basic_deliver, payload, %{delivery_tag: tag, redelivered: _redelivered} = metadata},
        state
      ) do
    Task.start(fn ->
      try do
        message =
          case Jason.decode(payload) do
            {:ok, encoded} -> encoded
            {:error, _} -> payload
          end

        result =
          :telemetry.span(
            [:hare_mq, :consumer, :message],
            %{queue: state.queue_name, exchange: state.exchange, routing_key: state.routing_key},
            fn ->
              r = state.consume_fn.(message)
              {r, %{result: consume_result_status(r), queue: state.queue_name, exchange: state.exchange, routing_key: state.routing_key}}
            end
          )

        process_result(result, payload, state, tag, metadata)
      rescue
        reason ->
          Logger.error(inspect(reason))
          retry(payload, state, tag, metadata)
      end
    end)

    {:noreply, state}
  end

  defp consume_result_status(:ok), do: :ok
  defp consume_result_status({:ok, _}), do: :ok
  defp consume_result_status(:error), do: :error
  defp consume_result_status({:error, _}), do: :error
  defp consume_result_status(_), do: :unknown

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.error("worker #{__MODULE__} was DOWN")
    {:stop, {:connection_lost, reason}, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, {:connection_lost, reason}, state}
  end

  def terminate(reason, state) do
    Logger.debug(
      "worker #{__MODULE__} was terminated with reason #{inspect(reason)} state #{inspect(state)}"
    )

    close_chan(state)
  end

  defp close_chan(%HareMq.Configuration{channel: nil}), do: :ok

  defp close_chan(state) do
    AMQP.Channel.close(state.channel)
  end

  defp stream_consume_opts(%HareMq.Configuration{stream: true, stream_offset: offset}) do
    [arguments: [stream_offset_arg(offset)]]
  end

  defp stream_consume_opts(_config), do: []

  defp stream_offset_arg(offset) when is_binary(offset), do: {"x-stream-offset", :longstr, offset}
  defp stream_offset_arg(offset) when is_integer(offset), do: {"x-stream-offset", :long, offset}
  defp stream_offset_arg(%DateTime{} = dt), do: {"x-stream-offset", :timestamp, DateTime.to_unix(dt)}
  defp stream_offset_arg(nil), do: {"x-stream-offset", :longstr, "next"}
end
