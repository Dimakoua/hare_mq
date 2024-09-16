require Logger
use AMQP

defmodule HareMq.Worker.Consumer do
  use GenServer

  @reconnect_interval Application.compile_env(:hare_mq, :configuration)[
                        :reconnect_interval_in_ms
                      ] || 10_000

  def start_link([config: config, consume: _] = opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {:consumers, config[:consumer_name]}}
    )
  end

  # start from Dynamic Supervisor
  def start_link({name, opts}) do
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {:consumers, name}})
  end

  def init([config: _, consume: _] = opts) do
    Process.flag(:trap_exit, true)

    send(self(), {:connect, opts})
    {:ok, %HareMq.Configuration{}}
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
    case HareMq.Connection.get_connection() do
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
                routing_key: config[:routing_key]
              )

            Basic.qos(chan, prefetch_count: config[:prefetch_count])

            declare_queues(queue_configuration)

            {:ok, consumer_tag} = Basic.consume(chan, config[:queue_name])

            {:noreply, HareMq.Configuration.set_consumer_tag(queue_configuration, consumer_tag)}

          _ ->
            Logger.error("[consumer_worker] Faile to open channel!")
            Process.send_after(self(), {:connect, opts}, @reconnect_interval)
            {:noreply, state}
        end

      {:error, _} ->
        Logger.error("[consumer_worker] Failed to connect. Reconnecting later...")
        # Retry later
        Process.send_after(self(), {:connect, opts}, @reconnect_interval)
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
    try do
      message =
        case Jason.decode(payload) do
          {:ok, encoded} -> encoded
          {:error, _} -> payload
        end

      state.consume_fn.(message)
      |> process_result(payload, state, tag, metadata)
    rescue
      reason ->
        Logger.error(inspect(reason))
        retry(payload, state, tag, metadata)
    end

    {:noreply, state}
  end

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
end
