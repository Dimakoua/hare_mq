defmodule HareMq do
  @moduledoc """
  HareMq is an Elixir library for interacting with AMQP systems such as RabbitMQ.
  It provides supervised connection management, queue/exchange topology declaration,
  message publishing with optional deduplication, message consumption with automatic
  retry/dead-letter routing, stream queue support, and dynamic consumer scaling with
  an optional auto-scaler.

  See the [README](https://github.com/Dimakoua/hare_mq) for full documentation.

  ---

  ## Publisher

  ```elixir
  defmodule MyApp.MessageProducer do
    use HareMq.Publisher,
      routing_key: "routing_key",
      exchange: "exchange"

    def send_message(message), do: publish_message(message)
  end
  ```

  With deduplication:

  ```elixir
  defmodule MyApp.MessageProducer do
    use HareMq.Publisher,
      routing_key: "routing_key",
      exchange: "exchange",
      unique: [
        period: :infinity,   # TTL in ms or :infinity
        keys: [:project_id]  # deduplicate by these map keys
      ]

    def send_message(message), do: publish_message(message)
  end
  ```

  `publish_message/1` returns `:ok`, `{:error, :not_connected}`,
  `{:error, {:encoding_failed, reason}}`, or `{:duplicate, :not_published}`.

  ---

  ## Consumer

  ```elixir
  defmodule MyApp.MessageConsumer do
    use HareMq.Consumer,
      queue_name: "queue_name",
      routing_key: "routing_key",
      exchange: "exchange"

    def consume(message) do
      IO.puts("Received: \#{inspect(message)}")
      :ok  # :ok | {:ok, any()} to ack; :error | {:error, any()} to retry
    end
  end
  ```

  ---

  ## Batch Consumer

  Batch processing allows processing multiple messages at once. Set `batch_size` and `batch_timeout_ms` to enable it.

  ```elixir
  defmodule MyApp.BatchConsumer do
    use HareMq.Consumer,
      queue_name: "my_queue",
      batch_size: 50,
      batch_timeout_ms: 2000

    def consume(messages, :batch) do
      # messages is a list of decoded payloads
      IO.puts("Received batch of \#{length(messages)} messages")
      :ok
    end
  end
  ```

  Batch processing is fully compatible with **retry**, **delay cascade**,
  **auto-scaling**, and **stream queues**. Each message in a batch is
  individually acknowledged or retried based on the return value of `consume/2`.

  ---

  ## Stream Consumer

  Stream queues are persistent, append-only logs. Each consumer reads at its own
  offset — messages are never removed after consumption.

  ```elixir
  defmodule MyApp.EventLog do
    use HareMq.Consumer,
      queue_name: "domain.events",
      stream: true,
      stream_offset: "first"   # replay from the beginning

    def consume(message) do
      IO.inspect(message)
      :ok
    end
  end
  ```

  `stream_offset` options: `"next"` (default), `"first"`, `"last"`,
  an integer offset, or a `%DateTime{}`.

  When `stream: true`:
  - Only the stream queue is declared (`x-queue-type: stream`).
  - No delay or dead-letter queues are created.
  - Messages are always acked regardless of the `consume_fn` return value.

  > **Prerequisite:** enable the `rabbitmq_stream` plugin on your broker:
  > `rabbitmq-plugins enable rabbitmq_stream`

  ---

  ## Dynamic Consumer

  ```elixir
  defmodule MyApp.MessageConsumer do
    use HareMq.DynamicConsumer,
      queue_name: "queue_name",
      routing_key: "routing_key",
      exchange: "exchange",
      consumer_count: 10

    def consume(message) do
      IO.puts("Received: \#{inspect(message)}")
      :ok
    end
  end
  ```

  With auto-scaling:

  ```elixir
  defmodule MyApp.MessageConsumer do
    use HareMq.DynamicConsumer,
      queue_name: "queue_name",
      routing_key: "routing_key",
      exchange: "exchange",
      consumer_count: 2,
      auto_scaling: [
        min_consumers: 1,
        max_consumers: 20,
        messages_per_consumer: 100,
        check_interval_ms: 5_000
      ]

    def consume(message), do: :ok
  end
  ```

  ---

  ## Usage in Application

  ```elixir
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        MyApp.MessageConsumer,
        MyApp.MessageProducer
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  ---

  ## Configuration

  ```elixir
  config :hare_mq, :amqp,
    url: "amqp://guest:guest@localhost:5672"

  config :hare_mq, :configuration,
    delay_in_ms: 10_000,
    retry_limit: 15,
    message_ttl_ms: 31_449_600,
    reconnect_interval_ms: 10_000

  config :hare_mq, :auto_scaler,
    min_consumers: 1,
    max_consumers: 20,
    messages_per_consumer: 10,
    check_interval_ms: 5_000
  ```

  All values are read at runtime via `Application.get_env`, so
  `Application.put_env` in tests takes effect without recompilation.

  ---

  ## Telemetry

  HareMq emits [Telemetry](https://hexdocs.pm/telemetry) events throughout its lifecycle.
  Attach handlers with `:telemetry.attach_many/4`:

      :telemetry.attach_many(
        "my-app-hare-mq",
        [
          [:hare_mq, :connection, :connected],
          [:hare_mq, :connection, :disconnected],
          [:hare_mq, :connection, :reconnecting],
          [:hare_mq, :consumer, :message, :stop],
          [:hare_mq, :retry_publisher, :message, :dead_lettered]
        ],
        fn event, measurements, metadata, _config ->
          require Logger
          Logger.info("[hare_mq] \#{inspect(event)} \#{inspect(measurements)} \#{inspect(metadata)}")
        end,
        nil
      )

  ### Connection events

  | Event | When |
  |---|---|
  | `[:hare_mq, :connection, :connected]` | Broker connection opened |
  | `[:hare_mq, :connection, :disconnected]` | Monitored connection process went down |
  | `[:hare_mq, :connection, :reconnecting]` | Reconnect attempt scheduled |

  ### Consumer events

  | Event | When |
  |---|---|
  | `[:hare_mq, :consumer, :connected]` | Channel open and `Basic.consume` called |
  | `[:hare_mq, :consumer, :message, :start]` | `consume/1` callback is about to be invoked |
  | `[:hare_mq, :consumer, :message, :stop]` | `consume/1` returned; stop metadata includes `:result` (`:ok`/`:error`) and `:duration` |
  | `[:hare_mq, :consumer, :message, :exception]` | `consume/1` raised an exception |

  The `:start`/`:stop`/`:exception` events follow the standard `:telemetry.span/3` contract.

  ### Publisher events

  | Event | When |
  |---|---|
  | `[:hare_mq, :publisher, :connected]` | Publisher channel opened |
  | `[:hare_mq, :publisher, :message, :published]` | Message published successfully |
  | `[:hare_mq, :publisher, :message, :not_connected]` | Publish attempted without a channel |

  ### Retry publisher events

  | Event | When |
  |---|---|
  | `[:hare_mq, :retry_publisher, :message, :retried]` | Failed message sent to a delay queue; measurements include `:retry_count` |
  | `[:hare_mq, :retry_publisher, :message, :dead_lettered]` | Message exceeded `retry_limit` and moved to dead-letter queue |

  See `HareMq.Telemetry` for the full measurements/metadata reference for each event.

  ## Rate Us:
  If you enjoy using HareMq, please consider giving us a star on GitHub! Your feedback and support are highly appreciated.
  [GitHub](https://github.com/Dimakoua/hare_mq)
  """
  use Application
  require Logger

  @doc """
  Starts the HareMq OTP application.

  Brings up two supervised children:
  - `HareMq.Connection` — manages the default AMQP connection.
  - `HareMq.DedupCache` — ETS-backed deduplication cache used by publishers with `unique:` set.

  Both are started under a `:one_for_one` supervisor.
  If you need additional connections (e.g. multiple vhosts) start named
  `HareMq.Connection` instances separately in your own supervision tree.
  """

  def start(_type, _args) do
    children = [
      HareMq.Connection,
      HareMq.DedupCache
    ]

    opts = [strategy: :one_for_one, name: HareMq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
