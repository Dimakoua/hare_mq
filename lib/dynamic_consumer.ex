defmodule HareMq.DynamicConsumer do
  defmodule Behaviour do
    @callback consume(map() | binary()) :: :ok | {:ok, any()} | :error | {:error, any()}
  end

  @moduledoc """
  Macro that injects a horizontally-scalable RabbitMQ consumer pool.

  Starts a `HareMq.DynamicSupervisor` that manages a configurable number of
  worker processes. Workers can be scaled manually or automatically via
  `HareMq.AutoScaler`.

  ## Usage

      defmodule MyApp.Workers do
        use HareMq.DynamicConsumer,
          queue_name: "tasks",
          consumer_count: 4

        def consume(message) do
          IO.inspect(message)
          :ok
        end
      end

  ## Options

  | Option | Required | Description |
  |---|---|---|
  | `queue_name` | yes | Main queue name |
  | `routing_key` | no | Defaults to `queue_name` |
  | `exchange` | no | AMQP exchange |
  | `prefetch_count` | no | QoS prefetch per worker (default `1`) |
  | `consumer_count` | no | Number of workers to start (default `1`) |
  | `auto_scaling` | no | `HareMq.AutoScalerConfiguration` — enables auto-scaling |
  | `delay_cascade_in_ms` | no | List of per-attempt delays, e.g. `[1_000, 5_000]` |
  | `connection_name` | no | Named connection for multi-vhost use (default `{:global, HareMq.Connection}`) |
  | `stream` | no | `true` to consume a stream queue (default `false`) |
  | `stream_offset` | no | Stream start position: `"first"`, `"last"`, `"next"` (default), integer offset, or `%DateTime{}` |

  When `stream: true` each worker declares an `x-queue-type: stream` queue,
  skips delay/dead-letter setup, and always acks messages (no retry loop).
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      @opts unquote(options)
      @behaviour HareMq.Consumer.Behaviour

      if(is_nil(@opts[:queue_name])) do
        raise "queue_name can not be empty"
      end

      @config [
        queue_name: @opts[:queue_name],
        routing_key: @opts[:routing_key] || @opts[:queue_name],
        exchange: @opts[:exchange],
        prefetch_count: @opts[:prefetch_count] || 1,
        consumer_count: @opts[:consumer_count] || 1,
        auto_scaling: @opts[:auto_scaling] || nil,
        delay_cascade_in_ms: @opts[:delay_cascade_in_ms],
        consumer_worker: HareMq.Worker.Consumer,
        module_name: __MODULE__,
        connection_name: @opts[:connection_name] || {:global, HareMq.Connection},
        stream: @opts[:stream] || false,
        stream_offset: @opts[:stream_offset] || "next"
      ]

      def child_spec(opts) do
        # shutdown: allows the supervisor up to this many ms for a graceful
        # :cancel_consume → worker-exit sequence. Defaults to 500 ms but can
        # be overridden via `shutdown_timeout:` in the consumer options.
        shutdown = @opts[:shutdown_timeout] || 500

        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: shutdown
        }
      end

      def start_link(opts \\ []) do
        HareMq.DynamicSupervisor.start_link(config: @config, consume: &consume/1)
      end

      def republish_dead_messages(count) do
        supervisor = HareMq.DynamicSupervisor.supervisor_name(__MODULE__)

        # Ask the supervisor for all live children in one call
        case DynamicSupervisor.which_children(supervisor) do
          [{_, pid, :worker, _} | _] when is_pid(pid) ->
            HareMq.Worker.Consumer.republish_dead_messages(pid, count)

          _ ->
            {:error, :process_not_alive}
        end
      end

      def consume(message) do
        raise "Implement me"
      end

      defoverridable(consume: 1)
    end
  end
end
