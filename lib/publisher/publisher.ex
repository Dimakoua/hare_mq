defmodule HareMq.Publisher do
  defmodule Behaviour do
    @callback publish_message(map() | binary()) :: :ok | {:error, reason :: :blocked | :closing}
  end

  @moduledoc """
  Macro that injects a full RabbitMQ publisher GenServer into the calling module.

  ## Usage

      defmodule MyApp.Producer do
        use HareMq.Publisher,
          routing_key: "my_key",   # required
          exchange: "my_exchange"  # optional; nil publishes to the default exchange
      end

  ## Options

  | Option | Required | Description |
  |---|---|---|
  | `routing_key` | yes | AMQP routing key |
  | `exchange` | no | Exchange name. Declared durable on connect. |
  | `unique` | no | Deduplication config: `[period: ttl_ms_or_infinity, keys: [:field]]` |
  | `connection_name` | no | Named connection for multi-vhost use (default `{:global, HareMq.Connection}`) |
  | `dedup_cache_name` | no | Named dedup cache (default `{:global, HareMq.DedupCache}`) |

  ## Return values of `publish_message/1`

  - `:ok` — message accepted by the broker.
  - `{:error, :not_connected}` — no active channel yet.
  - `{:error, {:encoding_failed, reason}}` — map could not be JSON-encoded.
  - `{:ok, :duplicate}` — deduplication prevented publishing (message already seen).
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      require Logger
      use GenServer
      @opts unquote(options)
      @behaviour HareMq.Publisher.Behaviour
      @before_compile unquote(__MODULE__)
      @connection_name @opts[:connection_name] || {:global, HareMq.Connection}
      @dedup_cache_name @opts[:dedup_cache_name] || {:global, HareMq.DedupCache}

      if(is_nil(@opts[:routing_key])) do
        raise "routing_key can not be empty"
      end

      @config [
        routing_key: @opts[:routing_key],
        exchange: @opts[:exchange]
      ]

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__})
        |> HareMq.CodeFlow.successful_start()
      end

      def init(_) do
        Process.flag(:trap_exit, true)
        send(self(), :connect)
        {:ok, nil}
      end

      def get_channel do
        case GenServer.call({:global, __MODULE__}, :get_channel) do
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
        case HareMq.Connection.get_connection(@connection_name) do
          {:ok, conn} ->
            # Get notifications when the connection goes down
            Process.monitor(conn.pid)

            case AMQP.Channel.open(conn) do
              {:ok, chan} ->
                Process.monitor(chan.pid)
                exchange = @config[:exchange]

                if exchange do
                  AMQP.Exchange.declare(chan, exchange, :topic, durable: true)
                end

                Process.put(:__hare_mq_connect_attempt__, 0)

                :telemetry.execute(
                  [:hare_mq, :publisher, :connected],
                  %{system_time: System.system_time()},
                  %{
                    publisher: __MODULE__,
                    exchange: @config[:exchange],
                    routing_key: @config[:routing_key]
                  }
                )

                {:noreply, chan}

              _ ->
                attempt = (Process.get(:__hare_mq_connect_attempt__) || 0) + 1
                Process.put(:__hare_mq_connect_attempt__, attempt)
                delay = backoff_delay(attempt)

                Logger.error(
                  "[publisher] Failed to open channel. Reconnecting in #{delay}ms (attempt #{attempt})..."
                )

                Process.send_after(self(), :connect, delay)
                {:noreply, state}
            end

          {:error, _} ->
            attempt = (Process.get(:__hare_mq_connect_attempt__) || 0) + 1
            Process.put(:__hare_mq_connect_attempt__, attempt)
            delay = backoff_delay(attempt)

            Logger.error(
              "[publisher] Failed to connect. Reconnecting in #{delay}ms (attempt #{attempt})..."
            )

            Process.send_after(self(), :connect, delay)
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

      defp reconnect_interval,
        do:
          (Application.get_env(:hare_mq, :configuration) || [])[:reconnect_interval_ms] ||
            10_000

      defp backoff_delay(attempt) do
        base = reconnect_interval()
        delay = trunc(base * :math.pow(2, min(attempt - 1, 5)))
        jitter = :rand.uniform(max(base, 1))
        min(delay + jitter, 60_000)
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep, generated: true do
      defp publish(message) when is_map(message) do
        case get_channel() do
          {:error, :not_connected} ->
            :telemetry.execute(
              [:hare_mq, :publisher, :message, :not_connected],
              %{system_time: System.system_time()},
              %{
                publisher: __MODULE__,
                exchange: @config[:exchange],
                routing_key: @config[:routing_key]
              }
            )

            {:error, :not_connected}

          {:ok, channel} ->
            case Jason.encode(message) do
              {:ok, encoded_message} ->
                result =
                  AMQP.Basic.publish(
                    channel,
                    @config[:exchange],
                    @config[:routing_key],
                    encoded_message,
                    persistent: true,
                    content_type: "application/json"
                  )

                :telemetry.execute(
                  [:hare_mq, :publisher, :message, :published],
                  %{system_time: System.system_time()},
                  %{
                    publisher: __MODULE__,
                    exchange: @config[:exchange],
                    routing_key: @config[:routing_key]
                  }
                )

                result

              {:error, reason} ->
                {:error, {:encoding_failed, reason}}
            end
        end
      end

      defp publish(message) when is_binary(message) do
        case get_channel() do
          {:error, :not_connected} ->
            :telemetry.execute(
              [:hare_mq, :publisher, :message, :not_connected],
              %{system_time: System.system_time()},
              %{
                publisher: __MODULE__,
                exchange: @config[:exchange],
                routing_key: @config[:routing_key]
              }
            )

            {:error, :not_connected}

          {:ok, channel} ->
            result =
              AMQP.Basic.publish(
                channel,
                @config[:exchange],
                @config[:routing_key],
                message,
                persistent: true
              )

            :telemetry.execute(
              [:hare_mq, :publisher, :message, :published],
              %{system_time: System.system_time()},
              %{
                publisher: __MODULE__,
                exchange: @config[:exchange],
                routing_key: @config[:routing_key]
              }
            )

            result
        end
      end

      @doc """
      Func for publishing messages.

      ## Examples

          defmodule MyPublisher do
            use HareMq.Publisher,
                exchange: "my_exchange",
                routing_key: "my_routing_key"
                unique: [
                  period: :infinity,
                  keys: [:project_id]
                ]

            def publish() do
              message = %{key: "value"}
              HareMq.Publisher.publish_message(message)
            end
          end
      """
      def publish_message(message) do
        unique = Keyword.get(@opts, :unique, [])
        deduplication_ttl = Keyword.get(unique, :period, nil)
        deduplication_keys = Keyword.get(unique, :keys, [])

        if(deduplication_ttl) do
          unless(HareMq.DedupCache.is_dup?(message, deduplication_keys, @dedup_cache_name)) do
            HareMq.DedupCache.add(
              message,
              deduplication_ttl,
              deduplication_keys,
              @dedup_cache_name
            )

            publish(message)
          else
            {:ok, :duplicate}
          end
        else
          publish(message)
        end
      end
    end
  end
end
