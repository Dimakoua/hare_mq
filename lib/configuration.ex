defmodule HareMq.Configuration do
  @moduledoc """
  Configuration module for HareMq.

  This module provides functions and structures for configuring various components of HareMq, such as queues, exchanges, and consumers. It allows you to specify parameters related to message handling, queue management, and connection settings.

  ## Structure

  The primary structure used in this module is `Configuration`, which holds the configuration details for a queue.

  ## Fields

  - `:channel` - The AMQP channel to use.
  - `:consume_fn` - The function to handle messages from the queue.
  - `:queue_name` - The name of the queue.
  - `:delay_queue_name` - The name of the delay queue.
  - `:dead_queue_name` - The name of the dead letter queue.
  - `:delay_cascade_in_ms` - A list of delays in milliseconds for cascading retries.
  - `:exchange` - The AMQP exchange.
  - `:routing_key` - The routing key for messages.
  - `:delay_in_ms` - The default delay in milliseconds before a message is retried.
  - `:message_ttl` - The time-to-live for a message in milliseconds.
  - `:retry_limit` - The number of retry attempts before a message is sent to the dead letter queue.
  - `:durable` - Whether the queue is durable or not.
  - `:consumer_tag` - An optional tag to identify the consumer.
  - `:state` - The current state of the configuration. Default is `:running`.

  ## Default Values

  The following defaults are set using application configuration or fallback values:

  - `@delay_in_ms`: `10_000`
  - `@retry_limit`: `15`
  - `@message_ttl`: `31_449_600`

  ## Examples

  Creating a queue configuration:

  ```elixir
  config = %Configuration{
    channel: my_channel,
    consume_fn: &my_consume_fn/1,
    queue_name: "my_queue",
    delay_queue_name: "my_queue.delay",
    dead_queue_name: "my_queue.dead",
    exchange: "my_exchange",
    routing_key: "my_routing_key",
    delay_in_ms: 10_000,
    delay_cascade_in_ms: [1000, 5000, 10000],
    message_ttl: 31_449_600,
    retry_limit: 15,
    durable: true,
    consumer_tag: nil,
    state: :running
  }
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
  def get_queue_configuration(
        channel: channel,
        consume_fn: consume_fn,
        name: name,
        exchange: exchange,
        routing_key: routing_key,
        delay_in_ms: delay_in_ms,
        retry_limit: retry_limit,
        delay_cascade_in_ms: delay_cascade_in_ms
      ) do
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
