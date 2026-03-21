defmodule HareMq.Configuration do
  @moduledoc """
  Runtime configuration struct and builder for HareMq queue consumers.

  ## Struct fields

  | Field | Description |
  |---|---|
  | `:channel` | Open `AMQP.Channel` for this consumer |
  | `:consume_fn` | Message handler — `(payload :: binary() -> :ok \| :error)` |
  | `:queue_name` | Main queue name |
  | `:delay_queue_name` | Derived delay queue (`queue_name <> ".delay"`) |
  | `:dead_queue_name` | Derived dead-letter queue (`queue_name <> ".dead"`) |
  | `:exchange` | AMQP exchange |
  | `:routing_key` | Routing key |
  | `:delay_in_ms` | Delay before first retry (runtime config or `10_000`) |
  | `:delay_cascade_in_ms` | List of per-retry delays, e.g. `[1_000, 5_000, 30_000]` |
  | `:message_ttl` | Queue-level message TTL in ms (runtime config or `31_449_600`) |
  | `:retry_limit` | Max retries before dead-lettering (runtime config or `15`) |
  | `:durable` | Always `true` |
  | `:consumer_tag` | Set after `Basic.consume/2` via `set_consumer_tag/2` |
  | `:state` | `:running` or `:cancelled` |

  ## Default resolution

  `delay_in_ms`, `retry_limit`, and `message_ttl` are resolved at call time via
  `Application.get_env(:hare_mq, :configuration)`, so runtime config changes
  (including `Application.put_env` in tests) take effect immediately.

  Passing `0` for `delay_in_ms` or `retry_limit` is honoured — the `||`
  operator is not used for nil-checks.
  """

  alias __MODULE__

  defstruct [
    :channel,
    :consume_fn,
    :queue_name,
    :delay_queue_name,
    :delay_cascade_in_ms,
    :dead_queue_name,
    :exchange,
    :routing_key,
    :delay_in_ms,
    :message_ttl,
    :retry_limit,
    :durable,
    :consumer_tag,
    :state
  ]

  @doc """
  Creates a configuration for a queue with the specified parameters.

  This function generates a `Configuration` struct, constructing names for delay and dead letter queues
  based on the provided queue name. It also allows setting advanced options like cascading delays for retries.

  ## Parameters

  - `channel`: The AMQP channel to use for the queue.
  - `consume_fn`: The function to handle messages from the queue.
  - `name`: The name of the queue.
  - `exchange`: The AMQP exchange to bind the queue to.
  - `routing_key`: The routing key to use for message routing.
  - `delay_in_ms` (optional): The delay in milliseconds before a message is retried. Defaults to `@delay_in_ms`.
  - `retry_limit` (optional): The number of retry attempts before messages are routed to the dead letter queue. Defaults to `@retry_limit`.
  - `delay_cascade_in_ms` (optional): A list of delays in milliseconds for cascading retries. Defaults to an empty list.

  ## Returns

  A `Configuration` struct with the specified and default parameters applied.

  ## Examples

  Creating a basic queue configuration:

  ```elixir
  config = get_queue_configuration(
    channel: my_channel,
    consume_fn: my_consume_fn,
    name: "my_queue",
    exchange: "my_exchange",
    routing_key: "my_routing_key"
  )

  """
  def get_queue_configuration(opts) when is_list(opts) do
    channel = Keyword.fetch!(opts, :channel)
    consume_fn = Keyword.fetch!(opts, :consume_fn)
    name = Keyword.fetch!(opts, :name)
    exchange = Keyword.get(opts, :exchange)
    routing_key = Keyword.get(opts, :routing_key, name)
    delay_in_ms = Keyword.get(opts, :delay_in_ms)
    retry_limit = Keyword.get(opts, :retry_limit)
    delay_cascade_in_ms = Keyword.get(opts, :delay_cascade_in_ms)

    %Configuration{
      channel: channel,
      consume_fn: consume_fn,
      queue_name: name,
      delay_queue_name: "#{name}.delay",
      dead_queue_name: "#{name}.dead",
      exchange: exchange,
      routing_key: routing_key,
      delay_in_ms: if(is_nil(delay_in_ms), do: config_value(:delay_in_ms, 10_000), else: delay_in_ms),
      delay_cascade_in_ms: delay_cascade_in_ms || [],
      message_ttl: config_value(:message_ttl, 31_449_600),
      retry_limit: if(is_nil(retry_limit), do: config_value(:retry_limit, 15), else: retry_limit),
      durable: true,
      consumer_tag: nil,
      state: :running
    }
  end

  @doc """
  Sets the consumer tag in the configuration.

  This function updates an existing `Configuration` struct with a new consumer tag.

  ## Parameters

    - `configuration`: The existing `Configuration` struct.
    - `consumer_tag`: The tag to set for the consumer.

  ## Examples

      updated_config = set_consumer_tag(config, "consumer_1")
  """
  defp config_value(key, default) do
    case (Application.get_env(:hare_mq, :configuration) || [])[key] do
      nil -> default
      value -> value
    end
  end

  def set_consumer_tag(%Configuration{} = configuration, consumer_tag) do
    %Configuration{configuration | consumer_tag: consumer_tag}
  end

  @doc """
  Updates the state in the configuration to indicate a cancel request.

  This function changes the `state` field in the `Configuration` struct to `:canceled`,
  which can be used to signal that the consumer should stop processing.

  ## Parameters

    - `configuration`: The existing `Configuration` struct.

  ## Examples

      updated_config = cancel_consume(config)
  """
  def cancel_consume(%Configuration{} = configuration) do
    %Configuration{configuration | state: :canceled}
  end
end
