defmodule HareMq.Configuration do
  @moduledoc """
  Configuration module for HareMq.

  This module provides functions for configuring HareMq components, such as queues and connections.
  """

  @doc """
  Structure representing the configuration for a queue.

  ## Fields

  - `:channel`: The AMQP channel.
  - `:queue_name`: The name of the queue.
  - `:delay_queue_name`: The name of the delay queue.
  - `:dead_queue_name`: The name of the dead letter queue.
  - `:exchange`: The AMQP exchange.
  - `:routing_key`: The routing key.
  - `:delay_in_ms`: The delay in milliseconds.
  - `:message_ttl`: The message time-to-live.
  - `:retry_limit`: The number of retry attempts.
  - `:durable`: Whether the queue is durable or not.

  ## Examples

      config = %Configuration{...}
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
    :durable
  ]

  @doc """
  Get the configuration for a queue.

  ## Examples

      config = get_queue_configuration(
        channel: channel,
        name: name,
        exchange: exchange,
        routing_key: routing_key
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
      durable: true
    }
  end
end
