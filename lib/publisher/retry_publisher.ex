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

    # Preserve all original headers; only replace retry_count
    base_headers = if is_list(headers), do: headers, else: []

    other_headers =
      Enum.reject(base_headers, fn
        {"retry_count", _, _} -> true
        _ -> false
      end)

    merged_headers = [{"retry_count", :long, retry_count + 1} | other_headers]

    if(retry_count < configuration.retry_limit) do
      Logger.debug("Sending message to a delay queue")
      republish_to_delay_queue(payload, configuration, retry_count, merged_headers)
    else
      Logger.debug("Sending message to a dead messages queue")

      :telemetry.execute(
        [:hare_mq, :retry_publisher, :message, :dead_lettered],
        %{retry_count: retry_count, system_time: System.system_time()},
        %{queue: configuration.queue_name, dead_queue: configuration.dead_queue_name}
      )

      AMQP.Basic.publish(
        configuration.channel,
        "",
        configuration.dead_queue_name,
        payload,
        persistent: true,
        headers: merged_headers
      )
    end
  end

  defp republish_to_delay_queue(
         payload,
         %Configuration{delay_cascade_in_ms: delay_cascade_in_ms} = configuration,
         retry_count,
         merged_headers
       )
       when is_list(delay_cascade_in_ms) and delay_cascade_in_ms != [] do
    retry_options = [persistent: true, headers: merged_headers]

    sorted = Enum.sort(delay_cascade_in_ms)

    delay_in_ms =
      if retry_count < length(sorted) do
        Enum.at(sorted, retry_count)
      else
        List.last(sorted)
      end

    delay_queue = "#{configuration.delay_queue_name}.#{delay_in_ms}"

    :telemetry.execute(
      [:hare_mq, :retry_publisher, :message, :retried],
      %{retry_count: retry_count + 1, system_time: System.system_time()},
      %{queue: configuration.queue_name, delay_queue: delay_queue}
    )

    AMQP.Basic.publish(
      configuration.channel,
      "",
      delay_queue,
      payload,
      retry_options
    )
  end

  defp republish_to_delay_queue(
         payload,
         %Configuration{} = configuration,
         retry_count,
         merged_headers
       ) do
    retry_options = [persistent: true, headers: merged_headers]

    :telemetry.execute(
      [:hare_mq, :retry_publisher, :message, :retried],
      %{retry_count: retry_count + 1, system_time: System.system_time()},
      %{queue: configuration.queue_name, delay_queue: configuration.delay_queue_name}
    )

    AMQP.Basic.publish(
      configuration.channel,
      "",
      configuration.delay_queue_name,
      payload,
      retry_options
    )
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
    |> Enum.reduce_while(:ok, fn _, _ ->
      case AMQP.Basic.get(configuration.channel, configuration.dead_queue_name) do
        {:empty, _} ->
          Logger.debug("Queue is empty")
          {:halt, :ok}

        {:ok, message, %{delivery_tag: tag}} ->
          :ok =
            AMQP.Basic.publish(
              configuration.channel,
              "",
              configuration.queue_name,
              message,
              persistent: true
            )

          :ok = AMQP.Basic.ack(configuration.channel, tag)
          {:cont, :ok}
      end
    end)
  end
end
