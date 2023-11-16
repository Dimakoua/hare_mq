defmodule HareMq.Consumer do
  defmodule Behaviour do
    @callback consume(map() | binary()) :: :ok | {:ok, any()} | :error | {:error, any()}
  end

  use AMQP

  @moduledoc """
  GenServer module implementing a RabbitMQ consumer.

  This module provides a behavior for RabbitMQ message consumption, including connecting to RabbitMQ, declaring queues, and handling incoming messages.
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      require Logger
      use GenServer

      @reconnect_interval Application.compile_env(:hare_mq, :configuration)[
                            :reconnect_interval_in_ms
                          ] || 10_000
      @opts unquote(options)
      @behaviour HareMq.Consumer.Behaviour
      @before_compile unquote(__MODULE__)

      if(is_nil(@opts[:queue_name])) do
        raise "queue_name can not be empty"
      end

      @config [
        queue_name: @opts[:queue_name],
        routing_key: @opts[:routing_key] || @opts[:queue_name],
        exchange: @opts[:exchange],
        prefetch_count: @opts[:prefetch_count] || 1
      ]

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(_) do
        Process.flag(:trap_exit, true)

        send(self(), :connect)
        {:ok, %HareMq.Configuration{}}
      end

      def declare_queues(channel, config) do
        :ok = HareMq.Exchange.declare(channel: config.channel, name: config.exchange)
        {:ok, _} = HareMq.Queue.declare_queue(config)
        {:ok, _} = HareMq.Queue.declare_delay_queue(config)
        {:ok, _} = HareMq.Queue.declare_dead_queue(config)
        :ok = HareMq.Queue.bind(config)
      end

      def handle_call(:get_channel, _, state) do
        {:reply, state, state}
      end

      def handle_call(:get_channel, _, state) do
        {:reply, state, state}
      end

      def handle_info(:connect, state) do
        case HareMq.Connection.get_connection() do
          {:ok, conn} ->
            # Get notifications when the connection goes down
            Process.monitor(conn.pid)

            case Channel.open(conn) do
              {:ok, chan} ->
                Process.monitor(chan.pid)

                config =
                  HareMq.Configuration.get_queue_configuration(
                    channel: chan,
                    name: @config[:queue_name],
                    exchange: @config[:exchange],
                    routing_key: @config[:routing_key]
                  )

                Basic.qos(chan, prefetch_count: @config[:prefetch_count])

                declare_queues(chan, config)

                {:ok, _consumer_tag} = Basic.consume(chan, @config[:queue_name])

                {:noreply, config}

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
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep, generated: true do
      @doc """
      Callback for processing incoming messages.

      Implement this callback in your consumer module to define how to handle incoming messages.

      ## Examples

          defmodule MyConsumer do
            use HareMq.Consumer, queue_name: "my_queue", routing_key: "my_routing_key"

            def consume(message) do
              IO.puts("Received message: \#{inspect(message)}")
              :ok
            end
          end
      """
      def consume(message) do
        raise "Implement me"
      end

      defoverridable(consume: 1)

      def get_channel do
        case GenServer.call(__MODULE__, :get_channel) do
          nil -> {:error, :not_connected}
          state -> {:ok, state}
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
            {:basic_deliver, payload, %{delivery_tag: tag, redelivered: redelivered} = metadata},
            state
          ) do
        try do
          message =
            case Jason.decode(payload) do
              {:ok, encoded} -> encoded
              {:error, _} -> payload
            end

          consume(message)
          |> process_result(payload, state, tag, metadata)
        rescue
          reason ->
            Logger.error(inspect(reason))
            retry(payload, state, tag, metadata)
        end

        {:noreply, state}
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

      def republish_dead_messages(count \\ 1) when is_number(count) do
        case get_channel() do
          {:error, :not_connected} ->
            {:error, :not_connected}

          {:ok, configures} ->
            HareMq.RetryPublisher.republish_dead_messages(configures, count)
        end
      end

      def terminate(_reason, state) do
        Logger.error("worker #{__MODULE__} was terminated with state #{inspect(state)}")
        close_chan(state)
      end

      def handle_info({:DOWN, _, :process, _pid, reason}, state) do
        Logger.error("worker #{__MODULE__} was DOWN")
        close_chan(state)
        {:stop, {:connection_lost, reason}, nil}
      end

      def handle_info({:EXIT, _pid, reason}, state) do
        close_chan(state)
        {:noreply, state}
      end

      defp close_chan(state) do
        try do
          AMQP.Channel.close(state.channel)
        rescue
          _ -> :ok
        end
      end
    end
  end
end
