defmodule HareMq.RetryPublisher do
  require Logger
  alias HareMq.Configuration

  def retry_count(:undefined), do: 0
  def retry_count([]), do: 0
  def retry_count([{"retry_count", :long, count} | _tail]), do: count
  def retry_count([_ | tail]), do: retry_count(tail)

  def republish(payload, %Configuration{} = configuration, %{headers: headers}) do
    retry_count = retry_count(headers)

    retry_options = [
      persistent: true,
      headers: [retry_count: retry_count + 1]
    ]

    if(retry_count < configuration.retry_limit) do
      Logger.debug("Sending message to a delay queue")

      AMQP.Basic.publish(
        configuration.channel,
        "",
        configuration.delay_queue_name,
        payload,
        retry_options
      )
    else
      Logger.debug("Sending message to a dead messages queue")

      AMQP.Basic.publish(
        configuration.channel,
        "",
        configuration.dead_queue_name,
        payload,
        retry_options
      )
    end
  end

  def republish_dead_messages(%Configuration{} = configuration, count) do
    0..(count - 1)
    |> Enum.each(fn _ ->
      case AMQP.Basic.get(configuration.channel, configuration.dead_queue_name) do
        {:empty, _} ->
          Logger.debug("Queue is empty")

        {:ok, message, %{delivery_tag: tag}} ->
          :ok =
            AMQP.Basic.publish(
              configuration.channel,
              configuration.exchange,
              configuration.routing_key,
              message,
              persistent: true
            )

          :ok = AMQP.Basic.ack(configuration.channel, tag)
      end
    end)
  end
end
