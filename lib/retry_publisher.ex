defmodule HareMq.RetryPublisher do
  require Logger
  alias HareMq.Configuration

  @moduledoc """
  Module providing functions for republishing messages with retry handling.

  This module includes functions for determining retry count, republishing to delay queues, and handling retries.
  """

  @doc """
  Determine the retry count from message headers.

  ## Parameters

  - `headers`: Message headers.

  ## Examples

      retry_count = HareMq.RetryPublisher.retry_count(headers)
  """
  def retry_count(:undefined), do: 0
  def retry_count([]), do: 0
  def retry_count([{"retry_count", :long, count} | _tail]), do: count
  def retry_count([_ | tail]), do: retry_count(tail)

  @doc """
  Republish a message to either a delay or dead letter queue based on the retry count.

  ## Parameters

  - `payload`: The message payload.
  - `configuration`: A `%Configuration{}` struct containing queue configuration.
  - `metadata`: Message metadata.

  ## Examples

      HareMq.RetryPublisher.republish(payload, configuration, metadata)
  """
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

  @doc """
  Republish a specified number of dead messages from the dead letter queue.

  ## Parameters

  - `configuration`: A `%Configuration{}` struct containing queue configuration.
  - `count`: The number of dead messages to republish.

  ## Examples

      HareMq.RetryPublisher.republish_dead_messages(configuration, 5)
  """
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
