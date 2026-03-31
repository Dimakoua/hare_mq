defmodule HareMq.Consumer do
  defmodule Behaviour do
    @callback consume(map() | binary()) :: :ok | {:ok, any()} | :error | {:error, any()}
    @callback consume(list(map() | binary()), :batch) ::
                :ok | {:ok, any()} | :error | {:error, any()}
  end

  @moduledoc """
  Macro that injects a single-process RabbitMQ consumer GenServer.

  ## Usage

      defmodule MyApp.Worker do
        use HareMq.Consumer,
          queue_name: "my_queue",   # required
          exchange: "my_exchange"

        def consume(message) do
          IO.inspect(message)
          :ok
        end
      end

  ## Batch Usage

      defmodule MyApp.BatchWorker do
        use HareMq.Consumer,
          queue_name: "my_queue",
          batch_size: 10

        def consume(messages, :batch) do
          IO.inspect(messages)
          :ok
        end
      end

  ## Options

  | Option | Required | Description |
  |---|---|---|
  | `queue_name` | yes | Main queue name |
  | `routing_key` | no | Defaults to `queue_name` |
  | `exchange` | no | AMQP exchange |
  | `prefetch_count` | no | QoS prefetch (default `1`) |
  | `delay_in_ms` | no | Retry delay in ms (default from app config or `10_000`) |
  | `delay_cascade_in_ms` | no | List of per-attempt delays, e.g. `[1_000, 5_000]` |
  | `retry_limit` | no | Max retries before dead-lettering (default from app config or `15`) |
  | `connection_name` | no | Named connection for multi-vhost use (default `{:global, HareMq.Connection}`) |
  | `stream` | no | `true` to consume a stream queue (default `false`) |
  | `stream_offset` | no | Stream start position: `"first"`, `"last"`, `"next"` (default), integer offset, or `%DateTime{}` |
  | `batch_size` | no | Number of messages to process in a single batch (default `1`) |
  | `batch_timeout_ms` | no | Timeout in ms to flush partial batches (default `5000`) |

  When `stream: true` the consumer declares an `x-queue-type: stream` queue,
  skips delay/dead-letter setup, and always acks messages (no retry loop).
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      require Logger

      @opts unquote(options)
      @behaviour HareMq.Consumer.Behaviour

      if(is_nil(@opts[:queue_name])) do
        raise "queue_name can not be empty"
      end

      @batch_size @opts[:batch_size] || 1
      @prefetch_count max(@opts[:prefetch_count] || 1, @batch_size)

      @config [
        queue_name: @opts[:queue_name],
        routing_key: @opts[:routing_key] || @opts[:queue_name],
        exchange: @opts[:exchange],
        retry_limit: @opts[:retry_limit],
        delay_in_ms: @opts[:delay_in_ms],
        prefetch_count: @prefetch_count,
        delay_cascade_in_ms: @opts[:delay_cascade_in_ms],
        consumer_name: __MODULE__,
        connection_name: @opts[:connection_name] || {:global, HareMq.Connection},
        stream: @opts[:stream] || false,
        stream_offset: @opts[:stream_offset] || "next",
        batch_size: @batch_size,
        batch_timeout_ms: @opts[:batch_timeout_ms] || 5000
      ]

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [[config: @config, consume: &consume/2]]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      def start_link(opts \\ []) do
        HareMq.Worker.Consumer.start_link(config: @config, consume: &consume/2)
      end

      def republish_dead_messages(number) do
        case :global.whereis_name(@config[:consumer_name]) do
          pid when is_pid(pid) -> HareMq.Worker.Consumer.republish_dead_messages(pid, number)
          _ -> {:error, :process_not_alive}
        end
      end

      def consume(message) do
        raise "Implement me"
      end

      def consume(message, :default) do
        consume(message)
      end

      def consume(messages, :batch) do
        raise "Implement me for batch"
      end

      defoverridable(consume: 1, consume: 2)
    end
  end
end
