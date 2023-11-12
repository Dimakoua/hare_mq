defmodule HareMq.Queue do
  alias HareMq.Configuration

  def bind(%Configuration{} = config) do
    AMQP.Queue.bind(config.channel, config.queue_name, config.exchange,
      routing_key: config.routing_key
    )
  end

  def declare_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.queue_name,
      durable: config.durable
    )
  end

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
