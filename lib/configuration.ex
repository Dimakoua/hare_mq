defmodule HareMq.Configuration do
  @moduledoc """
  Configuration module for HareMq.

  This module provides functions and structures for configuring various components of HareMq,
  such as queues, exchanges, and consumers. It allows you to specify parameters related to
  message handling, queue management, and connection settings.

  ## Structure

  The primary structure used in this module is `Configuration`, which holds the configuration
  details for a queue.

  ## Fields

  - `:channel` - The AMQP channel to use.
  - `:consume_fn` - The function to handle messages from the queue.
  - `:queue_name` - The name of the queue.
  - `:delay_queue_name` - The name of the delay queue.
  - `:dead_queue_name` - The name of the dead letter queue.
  - `:exchange` - The AMQP exchange.
  - `:routing_key` - The routing key for messages.
  - `:delay_in_ms` - The delay in milliseconds before a message is retried.
  - `:message_ttl` - The time-to-live for a message in milliseconds.
  - `:retry_limit` - The number of retry attempts before a message is sent to the dead letter queue.
  - `:durable` - Whether the queue is durable or not.
  - `:consumer_tag` - An optional tag to identify the consumer.
  - `:state` - The current state of the configuration. Default is `:running`.

  ## Examples

      config = %Configuration{
        channel: my_channel,
        consume_fn: &my_consume_fn/1,
        queue_name: "my_queue",
        delay_queue_name: "my_queue.delay",
        dead_queue_name: "my_queue.dead",
        exchange: "my_exchange",
        routing_key: "my_routing_key",
        delay_in_ms: 10_000,
        message_ttl: 31_449_600,
        retry_limit: 15,
        durable: true,
        consumer_tag: nil,
        state: :running
      }
  """
  alias __MODULE__

  @delay_in_ms Application.compile_env(:hare_mq, :configuration)[:delay_in_ms] || 10_000
  @retry_limit Application.compile_env(:hare_mq, :configuration)[:retry_limit] || 15
  @message_ttl Application.compile_env(:hare_mq, :configuration)[:message_ttl] || 31_449_600

  defstruct [
    :channel,
    :consume_fn,
    :queue_name,
    :delay_queue_name,
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

  This function generates a `Configuration` struct and constructs names for delay and dead letter queues
  based on the provided queue name.

  ## Parameters

    - `channel`: The AMQP channel to use.
    - `consume_fn`: The function to handle messages from the queue.
    - `name`: The name of the queue.
    - `exchange`: The AMQP exchange.
    - `routing_key`: The routing key for messages.

  ## Examples

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
        routing_key: routing_key
      ) do
    %Configuration{
      channel: channel,
      consume_fn: consume_fn,
      queue_name: name,
      delay_queue_name: "#{name}.delay",
      dead_queue_name: "#{name}.dead",
      exchange: exchange,
      routing_key: routing_key,
      delay_in_ms: @delay_in_ms,
      message_ttl: @message_ttl,
      retry_limit: @retry_limit,
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
