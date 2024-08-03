defmodule HareMq.Publisher do
  defmodule Behaviour do
    @callback publish_message(map() | binary()) :: :ok | {:error, reason :: :blocked | :closing}
  end

  @moduledoc """
  GenServer module implementing a RabbitMQ message publisher.

  This module provides a behavior for publishing messages to RabbitMQ, including connecting to RabbitMQ, declaring exchanges, and sending messages.
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      require Logger
      use GenServer
      @opts unquote(options)
      @reconnect_interval Application.compile_env(:hare_mq, :configuration)[
                            :reconnect_interval_in_ms
                          ] || 10_000
      @behaviour HareMq.Publisher.Behaviour
      @before_compile unquote(__MODULE__)

      if(is_nil(@opts[:routing_key])) do
        raise "routing_key can not be empty"
      end

      @config [
        routing_key: @opts[:routing_key],
        exchange: @opts[:exchange]
      ]

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(_) do
        Process.flag(:trap_exit, true)
        send(self(), :connect)
        {:ok, nil}
      end

      def get_channel do
        case GenServer.call(__MODULE__, :get_channel) do
          nil -> {:error, :not_connected}
          %AMQP.Channel{} = conn -> {:ok, conn}
        end
      end

      def handle_call(:get_channel, _, %AMQP.Channel{} = conn) do
        {:reply, conn, conn}
      end

      def handle_call(:get_channel, _, state) do
        {:reply, state, state}
      end

      def handle_info(:connect, state) do
        case HareMq.Connection.get_connection() do
          {:ok, conn} ->
            # Get notifications when the connection goes down
            Process.monitor(conn.pid)

            case AMQP.Channel.open(conn) do
              {:ok, chan} ->
                Process.monitor(chan.pid)
                {:noreply, chan}

              _ ->
                Logger.error("Faile to open channel!")
                Process.send_after(self(), :connect, @reconnect_interval)
                {:noreply, state}
            end

          {:error, _} ->
            Logger.error("Failed to connect. Reconnecting later...")
            # Retry later
            Process.send_after(self(), :connect, @reconnect_interval)
            {:noreply, nil}
        end
      end

      def handle_info({:DOWN, _, :process, _pid, reason}, state) do
        Logger.error("worker #{__MODULE__} was DOWN")
        {:stop, {:connection_lost, reason}, state}
      end

      def handle_info({:EXIT, _pid, reason}, state) do
        {:stop, {:connection_lost, reason}, state}
      end

      def handle_info(reason, state) do
        {:stop, {:connection_lost, reason}, state}
      end

      def terminate(reason, state) do
        Logger.debug(
          "worker #{__MODULE__} was terminated #{inspect(reason)} with state #{inspect(state)}"
        )

        close_chan(state)
      end

      defp close_chan(%AMQP.Channel{} = channel) do
        if Process.alive?(channel.pid) do
          AMQP.Channel.close(channel)
        end
      end

      defp close_chan(_), do: :ok
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep, generated: true do
      def publish_message(message) when is_map(message) do
        case get_channel() do
          {:error, :not_connected} ->
            {:error, :not_connected}

          {:ok, channel} ->
            encoded_message = Jason.encode!(message)

            AMQP.Basic.publish(
              channel,
              @config[:exchange],
              @config[:routing_key],
              encoded_message,
              persistent: true
            )
        end
      end

      @doc """
      Func for publishing messages.

      ## Examples

          defmodule MyPublisher do
            use HareMq.Publisher, exchange: "my_exchange", routing_key: "my_routing_key"

            def publish() do
              message = %{key: "value"}
              HareMq.Publisher.publish_message(message)
            end
          end
      """
      def publish_message(message) when is_binary(message) do
        case get_channel() do
          {:error, :not_connected} ->
            {:error, :not_connected}

          {:ok, channel} ->
            AMQP.Basic.publish(
              channel,
              @config[:exchange],
              @config[:routing_key],
              message,
              persistent: true
            )
        end
      end
    end
  end
end
