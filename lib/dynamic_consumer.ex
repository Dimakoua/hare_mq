defmodule HareMq.DynamicConsumer do
  defmodule Behaviour do
    @callback consume(map() | binary()) :: :ok | {:ok, any()} | :error | {:error, any()}
  end

  @moduledoc """
  This module provides a dynamic supervisor for managing worker processes in the HareMq application.
  It is designed to start a configurable number of consumer processes to handle message consumption.
  """

  defmacro __using__(options) do
    quote location: :keep, generated: true do
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
        consumer_count: @opts[:consumer_count] || 1,
        consumer_worker: HareMq.Worker.Consumer
      ]

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      def start_link(opts \\ []) do
        HareMq.DynamicSupervisor.start_link(config: @config, consume: &consume/1)
      end

      def republish_dead_messages(count), do: traverse_consumers(count, 1)

      defp traverse_consumers(count, consumer_number) do
        if consumer_number == @config[:consumer_count] do
          {:error, :process_not_alive}
        else
          case Registry.lookup(:consumers, "#{@config[:consumer_worker]}.W#{consumer_number}") do
            [{pid, nil}] -> HareMq.Worker.Consumer.republish_dead_messages(pid, count)
            _ -> traverse_consumers(count, consumer_number + 1)
          end
        end
      end

      def consume(message) do
        raise "Implement me"
      end

      defoverridable(consume: 1)
    end
  end
end
