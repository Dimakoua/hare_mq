defmodule HareMq.Configuration do
  alias __MODULE__

  @delay_in_ms Application.compile_env(:hare_mq, :configuration)[:delay_in_ms] || 10_000
  @retry_limit Application.compile_env(:hare_mq, :configuration)[:retry_limit] || 15
  @message_ttl Application.compile_env(:hare_mq, :configuration)[:message_ttl] || 31_449_600

  defstruct [
    :channel,
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

  def get_queue_configuration(
        channel: channel,
        name: name,
        exchange: exchange,
        routing_key: routing_key
      ) do
    %Configuration{
      channel: channel,
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
