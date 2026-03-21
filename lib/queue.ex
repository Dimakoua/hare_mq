defmodule HareMq.Queue do
  alias HareMq.Configuration

  @moduledoc """
  Functions for declaring and binding RabbitMQ queues.

  Supports three queue families:

  - **Standard queues** — `declare_queue/1`: durable classic or quorum queue.
  - **Delay / dead-letter queues** — `declare_delay_queue/1` and
    `declare_dead_queue/1`: used automatically by the retry pipeline.
  - **Stream queues** — `declare_stream_queue/1`: persistent, append-only log
    declared with `x-queue-type: stream`. No delay or dead-letter queues are
    created for stream consumers.
  """

  @doc """
  Binds a queue to an exchange using the routing key in `config`.

  For stream queues the user-supplied `config.exchange` is used as the source
  exchange. For classic queues the exchange is named after the queue itself
  (`config.queue_name`), which is the dead-letter exchange declared alongside it.
  """
  def bind(%Configuration{stream: true} = config) do
    AMQP.Queue.bind(config.channel, config.queue_name, config.exchange,
      routing_key: config.routing_key
    )
  end

  def bind(%Configuration{} = config) do
    AMQP.Queue.bind(config.channel, config.queue_name, config.queue_name,
      routing_key: config.routing_key
    )
  end

  @doc """
  Declares a durable RabbitMQ queue (classic or quorum).
  """
  def declare_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.queue_name,
      durable: config.durable
    )
  end

  @doc """
  Declares the delay queue(s) used by the retry pipeline.

  When `delay_cascade_in_ms` is a non-empty list each delay value gets its own
  named queue (`queue_name.delay.<ms>`) with a matching `x-message-ttl` and
  dead-letter routing back to the main queue. Otherwise a single
  `queue_name.delay` queue is created using `delay_in_ms`.
  """
  def declare_delay_queue(%Configuration{delay_cascade_in_ms: [_ | _] = delay_cascade_in_ms} = config) do
    delay_cascade_in_ms
    |> Enum.sort()
    |> Enum.each(fn delay_in_ms when is_integer(delay_in_ms) ->
      {:ok, _} =
        AMQP.Queue.declare(
          config.channel,
          "#{config.delay_queue_name}.#{delay_in_ms}",
          durable: config.durable,
          arguments: [
            {"x-dead-letter-exchange", :longstr, config.queue_name},
            {"x-dead-letter-routing-key", :longstr, config.routing_key},
            {"x-message-ttl", :long, delay_in_ms}
          ]
        )
    end)

    {:ok, :created}
  end

  def declare_delay_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.delay_queue_name,
      durable: config.durable,
      arguments: [
        {"x-dead-letter-exchange", :longstr, config.queue_name},
        {"x-dead-letter-routing-key", :longstr, config.routing_key},
        {"x-message-ttl", :long, config.delay_in_ms}
      ]
    )
  end

  @doc """
  Declares the dead-letter queue (`queue_name.dead`) with `x-message-ttl`.
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

  @doc """
  Declares a durable RabbitMQ stream queue.

  Stream queues are persistent, append-only logs. Messages are not removed
  after consumption — each consumer maintains its own offset.

  The queue is declared with `x-queue-type: stream`. No exchange binding,
  delay queue, or dead-letter queue is needed for stream consumers.
  """
  def declare_stream_queue(%Configuration{} = config) do
    AMQP.Queue.declare(
      config.channel,
      config.queue_name,
      durable: true,
      arguments: [{"x-queue-type", :longstr, "stream"}]
    )
  end
end
