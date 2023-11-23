defmodule HareMq.Worker.Consumer do
  require Logger
  use AMQP
  use GenServer

  @reconnect_interval Application.compile_env(:hare_mq, :configuration)[
                        :reconnect_interval_in_ms
                      ] || 10_000

  def start_link([config: config, consume: _] = opts) do
    IO.inspect("LDLDLDLLD")
    IO.inspect(__MODULE__)
    IO.inspect(config[:consumer_name])
    GenServer.start_link(__MODULE__, opts, name: config[:consumer_name])
    |> IO.inspect
  end

  def init([config: _, consume: _] = opts) do
    Process.flag(:trap_exit, true)

    send(self(), {:connect, opts})
    {:ok, %HareMq.Configuration{}}
  end

  def declare_queues(config) do
    :ok = HareMq.Exchange.declare(channel: config.channel, name: config.exchange)
    {:ok, _} = HareMq.Queue.declare_queue(config)
    {:ok, _} = HareMq.Queue.declare_delay_queue(config)
    {:ok, _} = HareMq.Queue.declare_dead_queue(config)
    :ok = HareMq.Queue.bind(config)
  end

  def get_channel(consumer_name) do
    case GenServer.call(consumer_name, :get_channel) |> IO.inspect() do
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
    IO.inspect("DLDLDLDLDLDLDL")
    IO.inspect(consumer_name)

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

  def handle_info({:connect, [config: config, consume: consume]}, state) do
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

            {:ok, _consumer_tag} = Basic.consume(chan, config[:queue_name])

            {:noreply, queue_configuration}

          _ ->
            Logger.error("Faile to open channel!")
            Process.send_after(self(), :send, @reconnect_interval)
            {:noreply, state}
        end

      {:error, _} ->
        Logger.error("Failed to connect. Reconnecting later...")
        # Retry later
        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, state}
    end
  end

  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    Logger.warn(
      "Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)"
    )

    {:stop, :normal, state}
  end

  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
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
    close_chan(state)
    {:stop, {:connection_lost, reason}, nil}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    close_chan(state)
    {:noreply, state}
  end

  def terminate(_reason, state) do
    Logger.error("worker #{__MODULE__} was terminated with state #{inspect(state)}")
    close_chan(state)
  end

  defp close_chan(state) do
    try do
      AMQP.Channel.close(state.channel)
    rescue
      _ -> :ok
    end
  end
end
