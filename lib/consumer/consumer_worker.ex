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
    do: (Application.get_env(:hare_mq, :configuration) || [])[:reconnect_interval_ms] || 10_000

  defp backoff_delay(attempt) do
    base = reconnect_interval()
    delay = trunc(base * :math.pow(2, min(attempt - 1, 5)))
    jitter = :rand.uniform(max(base, 1))
    min(delay + jitter, 60_000)
  end

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

  def republish_dead_messages(consumer_name, count \\ 1) when is_number(count) do
    case GenServer.call(consumer_name, :get_channel) do
      nil ->
        {:error, :not_connected}

      configures ->
        HareMq.RetryPublisher.republish_dead_messages(configures, count)
    end
  end

  def handle_call(:get_channel, _, state) do
    {:reply, state, state}
  end

  def handle_call(:get_config, _, state) do
    {:reply, state, state}
  end

  def handle_call(:cancel_consume, from, state) do
    Basic.cancel(state.channel, state.consumer_tag)
    state = HareMq.Configuration.cancel_consume(state)

    if MapSet.size(state.in_flight) == 0 do
      {:reply, :ok, state}
    else
      timeout =
        (Application.get_env(:hare_mq, :configuration) || [])[:shutdown_drain_timeout_ms] ||
          5_000

      Process.send_after(self(), :drain_timeout, timeout)
      {:noreply, %{state | drain_caller: from}}
    end
  end

  def handle_info({:connect, [config: config, consume: consume] = opts}, state) do
    case HareMq.Connection.get_connection(
           config[:connection_name] || {:global, HareMq.Connection}
         ) do
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
                stream_offset: config[:stream_offset],
                batch_size: config[:batch_size] || 1,
                batch_timeout_ms: config[:batch_timeout_ms] || 5000
              )

            Basic.qos(chan, prefetch_count: config[:prefetch_count])

            declare_queues(queue_configuration)

            {:ok, consumer_tag} =
              Basic.consume(
                chan,
                config[:queue_name],
                nil,
                stream_consume_opts(queue_configuration)
              )

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

            Process.put(:__hare_mq_connect_attempt__, 0)
            {:noreply, HareMq.Configuration.set_consumer_tag(queue_configuration, consumer_tag)}

          _ ->
            attempt = (Process.get(:__hare_mq_connect_attempt__) || 0) + 1
            Process.put(:__hare_mq_connect_attempt__, attempt)
            delay = backoff_delay(attempt)

            Logger.error(
              "[consumer_worker] Failed to open channel. Reconnecting in #{delay}ms (attempt #{attempt})..."
            )

            Process.send_after(self(), {:connect, opts}, delay)
            {:noreply, state}
        end

      {:error, _} ->
        attempt = (Process.get(:__hare_mq_connect_attempt__) || 0) + 1
        Process.put(:__hare_mq_connect_attempt__, attempt)
        delay = backoff_delay(attempt)

        Logger.error(
          "[consumer_worker] Failed to connect. Reconnecting in #{delay}ms (attempt #{attempt})..."
        )

        Process.send_after(self(), {:connect, opts}, delay)
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
        {:basic_deliver, payload, %{delivery_tag: _tag, redelivered: _redelivered} = metadata},
        state
      ) do
    new_pending = state.pending_batch ++ [{payload, metadata}]

    if length(new_pending) >= state.batch_size do
      # Batch is full — cancel timer and process immediately
      if state.batch_timer_ref do
        Process.cancel_timer(state.batch_timer_ref)
      end

      new_state = process_batch(new_pending, state)
      {:noreply, %{new_state | pending_batch: [], batch_timer_ref: nil}}
    else
      # Batch not full yet — start timer if this is the first message
      timer_ref =
        if state.pending_batch == [] do
          Process.send_after(self(), :batch_timeout, state.batch_timeout_ms)
        else
          state.batch_timer_ref
        end

      {:noreply, %{state | pending_batch: new_pending, batch_timer_ref: timer_ref}}
    end
  end

  @doc false
  def handle_info(:batch_timeout, state) do
    if state.pending_batch != [] do
      # Flush partial batch on timeout
      new_state = process_batch(state.pending_batch, state)
      {:noreply, %{new_state | pending_batch: [], batch_timer_ref: nil}}
    else
      {:noreply, %{state | batch_timer_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if MapSet.member?(state.in_flight, ref) do
      new_in_flight = MapSet.delete(state.in_flight, ref)
      new_state = %{state | in_flight: new_in_flight}

      if MapSet.size(new_in_flight) == 0 and not is_nil(state.drain_caller) do
        GenServer.reply(state.drain_caller, :ok)
        {:noreply, %{new_state | drain_caller: nil}}
      else
        {:noreply, new_state}
      end
    else
      # Clean up batch timer and nack any pending messages
      if state.batch_timer_ref do
        Process.cancel_timer(state.batch_timer_ref)
      end

      Enum.each(state.pending_batch, fn {_payload, metadata} ->
        Basic.nack(state.channel, metadata.delivery_tag, multiple: false, requeue: false)
      end)

      Logger.error("worker #{__MODULE__} was DOWN")
      {:stop, {:connection_lost, reason}, state}
    end
  end

  def handle_info(:drain_timeout, %{drain_caller: nil} = state), do: {:noreply, state}

  def handle_info(:drain_timeout, state) do
    Logger.warning(
      "[consumer_worker] Shutdown drain timed out: #{MapSet.size(state.in_flight)} task(s) still running"
    )

    GenServer.reply(state.drain_caller, :ok)
    {:noreply, %{state | drain_caller: nil}}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, {:connection_lost, reason}, state}
  end


  defp process_batch(batch, state) do
    {:ok, pid} =
      Task.start(fn ->
        try do
          {type, data} =
            if state.batch_size > 1 do
              messages = Enum.map(batch, fn {p, m} -> decode_payload(p, m) end)
              {:batch, messages}
            else
              {payload, metadata} = List.first(batch)
              {:default, decode_payload(payload, metadata)}
            end

          result =
            :telemetry.span(
              [:hare_mq, :consumer, :message],
              %{
                queue: state.queue_name,
                exchange: state.exchange,
                routing_key: state.routing_key
              },
              fn ->
                r = state.consume_fn.(data, type)

                {r,
                 %{
                   result: consume_result_status(r),
                   queue: state.queue_name,
                   exchange: state.exchange,
                   routing_key: state.routing_key
                 }}
              end
            )

          process_batch_result(result, batch, state)
        rescue
          reason ->
            Logger.error(inspect(reason))
            retry_batch(batch, state)
        end
      end)

    ref = Process.monitor(pid)
    %{state | in_flight: MapSet.put(state.in_flight, ref)}
  end

  defp process_batch_result(_result, batch, %{stream: true} = state) do
    ack_batch(batch, state)
  end

  defp process_batch_result(result, batch, state) do
    case result do
      :ok -> ack_batch(batch, state)
      {:ok, _} -> ack_batch(batch, state)
      :error -> retry_batch(batch, state)
      {:error, _} -> retry_batch(batch, state)
    end
  end

  defp ack_batch(batch, state) do
    Enum.each(batch, fn {_payload, metadata} ->
      Basic.ack(state.channel, metadata.delivery_tag, multiple: false)
    end)
  end

  defp retry_batch(batch, state) do
    Task.start(fn ->
      {_successful, failed} = republish_batch_messages(batch, state)

      if failed > 0 do
        Logger.warning(
          "[consumer_worker] Batch republish: #{failed}/#{length(batch)} messages will be redelivered"
        )
      end
    end)
  end

  defp republish_batch_messages(batch, state) do
    Enum.reduce(batch, {0, 0}, fn {payload, metadata}, {ok_count, err_count} ->
      case try_republish_message(payload, state, metadata) do
        :ok ->
          case try_nack_message(state, metadata) do
            :ok -> {ok_count + 1, err_count}
            :error -> {ok_count, err_count + 1}
          end

        :error ->
          {ok_count, err_count + 1}
      end
    end)
  end

  defp try_republish_message(payload, state, metadata) do
    try do
      HareMq.RetryPublisher.republish(payload, state, metadata)
      :ok
    rescue
      e ->
        Logger.error(
          "[consumer_worker] batch republish failed for tag #{metadata.delivery_tag}: #{inspect(e)} — message will be redelivered"
        )

        :error
    catch
      :exit, e ->
        Logger.error(
          "[consumer_worker] batch republish exited for tag #{metadata.delivery_tag}: #{inspect(e)} — message will be redelivered"
        )

        :error
    end
  end

  defp try_nack_message(state, metadata) do
    try do
      Basic.nack(state.channel, metadata.delivery_tag, multiple: false, requeue: false)
      :ok
    rescue
      _ -> :error
    end
  end

  defp consume_result_status(:ok), do: :ok
  defp consume_result_status({:ok, _}), do: :ok
  defp consume_result_status(:error), do: :error
  defp consume_result_status({:error, _}), do: :error
  defp consume_result_status(_), do: :unknown

  # Decode the payload to a term only when the content_type indicates JSON.
  # For binary payloads (no content_type or non-JSON) skip the decode attempt
  # entirely so high-throughput binary queues don't pay the JSON parse cost.
  defp decode_payload(payload, %{content_type: "application/json"}) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  defp decode_payload(payload, _metadata) do
    # No content_type set — attempt JSON decode for backward compatibility
    # with publishers that don't set the header, fall back to raw binary.
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  def terminate(reason, state) do
    Logger.debug(
      "worker #{__MODULE__} was terminated with reason #{inspect(reason)} state #{inspect(state)}"
    )

    # Clean up batch timer
    if state.batch_timer_ref do
      Process.cancel_timer(state.batch_timer_ref)
    end

    # Nack any pending batch messages
    Enum.each(state.pending_batch, fn {_payload, metadata} ->
      try do
        Basic.nack(state.channel, metadata.delivery_tag, multiple: false, requeue: false)
      rescue
        _ -> :ok
      end
    end)

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

  defp stream_offset_arg(%DateTime{} = dt),
    do: {"x-stream-offset", :timestamp, DateTime.to_unix(dt)}

  defp stream_offset_arg(nil), do: {"x-stream-offset", :longstr, "next"}
end
