defmodule HareMq.DynamicConsumer do
  defmodule Behaviour do
    @callback consume(map() | binary()) :: :ok | {:ok, any()} | :error | {:error, any()}
  end

  @moduledoc """
  GenServer module implementing a RabbitMQ consumer.

  This module provides a behavior for RabbitMQ message consumption, including connecting to RabbitMQ, declaring queues, and handling incoming messages.
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
      require Logger

      @opts unquote(options)
      @behaviour HareMq.Consumer.Behaviour

      if(is_nil(@opts[:queue_name])) do
        raise "queue_name can not be empty"
      end

      @config [
        queue_name: @opts[:queue_name],
        routing_key: @opts[:routing_key] || @opts[:queue_name],
        exchange: @opts[:exchange],
        prefetch_count: @opts[:prefetch_count] || 1,
        consumer_count: @opts[:consumer_count] || 1
      ]

      def start_link(opts \\ []) do
        HareMq.DynamicSupervisor.start_link(config: @config, consume: &consume/1)
      end

      def consume(message) do
        raise "Implement me"
      end

      defoverridable(consume: 1)
    end
  end
end
