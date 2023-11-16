defmodule HareMq.Exchange do
  @default_type Application.compile_env(:hare_mq, :exchange_type, :direct)

  @moduledoc """
  Module providing functions for managing RabbitMQ exchanges.

  This module includes functions for declaring and binding exchanges.
  """

  @doc """
  Declare a RabbitMQ exchange.

  ## Parameters

  - `:channel`: The AMQP channel.
  - `:name`: The name of the exchange.
  - `:type`: The type of the exchange.

  ## Examples

      HareMq.Exchange.declare(channel: channel, name: "my_exchange", type: :direct)
      HareMq.Exchange.declare(channel: channel, name: "my_exchange")
  """
  def declare(channel: channel, name: name, type: type) do
    AMQP.Exchange.declare(channel, name, type, durable: true)
  end

  def declare(channel: channel, name: name) do
    AMQP.Exchange.declare(channel, name, @default_type, durable: true)
  end

  @doc """
  Bind a RabbitMQ exchange to a destination.

  ## Parameters

  - `:channel`: The AMQP channel.
  - `:destination`: The name of the destination exchange or queue.
  - `:source`: The name of the source exchange.
  - `:routing_key`: The routing key.

  ## Examples

      HareMq.Exchange.bind(channel: channel, destination: "destination_exchange", source: "my_exchange", routing_key: "my_routing_key")
  """
  def bind(channel: channel, destination: destination, source: source, routing_key: routing_key) do
    AMQP.Exchange.bind(channel, destination, source, routing_key: routing_key)
  end
end
