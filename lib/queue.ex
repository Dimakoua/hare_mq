defmodule HareMq.Queue do
  alias HareMq.Configuration

  @moduledoc """
  Module providing functions for managing RabbitMQ queues.

  This module includes functions for declaring queues and binding them to exchanges.
  """

  @doc """
  Bind a queue to an exchange with the specified routing key.

  ## Parameters

  - `config`: A `%Configuration{}` struct containing queue configuration.

  ## Examples

      HareMq.Queue.bind(%Configuration{channel: channel, queue_name: "my_queue", exchange: "my_exchange", routing_key: "my_routing_key"})
  """
  def bind(%Configuration{} = config) do
    AMQP.Queue.bind(config.channel, config.queue_name, config.exchange,
      routing_key: config.routing_key
    )
  end

  @doc """
  Declare a durable RabbitMQ queue.

  ## Parameters

  - `config`: A `%Configuration{}` struct containing queue configuration.

  ## Examples

      HareMq.Queue.declare_queue(%Configuration{channel: channel, queue_name: "my_queue", durable: true})
  """
  def declare_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.queue_name,
      durable: config.durable
    )
  end

  @doc """
  Declare a durable RabbitMQ delay queue with specified options.

  ## Parameters

  - `config`: A `%Configuration{}` struct containing queue configuration.

  ## Examples

      HareMq.Queue.declare_delay_queue(%Configuration{channel: channel, delay_queue_name: "my_queue.delay", exchange: "my_exchange", routing_key: "my_routing_key", delay_in_ms: 5000})
  """
  def declare_delay_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.delay_queue_name,
      durable: config.durable,
      arguments: [
        {"x-dead-letter-exchange", :longstr, config.exchange},
        {"x-dead-letter-routing-key", :longstr, config.routing_key},
        {"x-message-ttl", :long, config.delay_in_ms}
      ]
    )
  end

  @doc """
  Declare a durable RabbitMQ dead letter queue with specified options.

  ## Parameters

  - `config`: A `%Configuration{}` struct containing queue configuration.

  ## Examples

      HareMq.Queue.declare_dead_queue(%Configuration{channel: channel, dead_queue_name: "my_queue.dead", message_ttl: 3600000})
  """
  def declare_dead_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.dead_queue_name,
      durable: config.durable,
      arguments: [
        {"x-message-ttl", :long, config.message_ttl}
      ]
    )
  end
end
