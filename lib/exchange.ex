defmodule HareMq.Exchange do
  @default_type Application.compile_env(:hare_mq, :exchange_type, :direct)

  def declare(channel: channel, name: name, type: type) do
    AMQP.Exchange.declare(channel, name, type, durable: true)
  end

  def declare(channel: channel, name: name) do
    AMQP.Exchange.declare(channel, name, @default_type, durable: true)
  end

  def bind(channel: channel, destination: destination, source: source, routing_key: routing_key) do
    AMQP.Exchange.bind(channel, destination, source, routing_key: routing_key)
  end
end
